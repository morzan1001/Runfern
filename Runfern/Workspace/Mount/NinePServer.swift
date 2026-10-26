import Darwin
import Foundation
import Synchronization

/// Serves one folder to the Linux guest over 9P2000.L, so Linux mounts it directly at `/workspace`
/// (`mount -t 9p -o trans=tcp …`). Nothing is copied: every read and write goes to the folder.
///
/// The guest runs code from the internet (packages, build scripts), so the server treats it as
/// untrusted and confines it to the folder:
/// - It listens on 127.0.0.1 only; the guest reaches it as 10.0.2.2 through QEMU's user network.
///   Other apps on the iPad can connect too, so nothing works before a client names the session
///   token (256 random bits, compared in constant time), and a wrong token ends the connection.
/// - Paths are resolved one directory at a time from an open descriptor of the folder, and the
///   server never follows a symbolic link, neither in the middle of a path nor at its end. Links
///   the guest creates are only ever read back as links; the guest's kernel resolves them itself.
/// - Every change goes through the `…at` system calls on the resolved directory, so swapping a
///   directory for a link between two requests can't redirect it either.
/// - Connections, open files, and message sizes are limited.
nonisolated final class NinePServer: @unchecked Sendable {
    let root: URL
    let token: String
    /// Owner reported for every file: the guest's `runfern` user, which the app's own files map to.
    let owner: (uid: UInt32, gid: UInt32)
    private(set) var port: Int = 0

    /// Open descriptor of `root`, the base of every path.
    fileprivate private(set) var rootDescriptor: Int32 = -1
    private var listener: Int32 = -1
    private let connections = Mutex<[Int32]>([])

    /// The guest mounts once; a few more connections allow a remount while the old one closes.
    static let maximumConnections = 4

    init(root: URL, token: String, owner: (uid: UInt32, gid: UInt32) = (501, 1000)) {
        self.root = root
        self.token = token
        self.owner = owner
    }

    deinit { stop() }

    /// Starts listening on a free loopback port and returns it.
    @discardableResult
    func start() throws -> Int {
        let directory = open(root.path(percentEncoded: false), O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw NinePError.current }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            close(directory)
            throw NinePError.current
        }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && listen(fd, 4) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        guard ok else {
            let error = NinePError.current
            close(fd)
            close(directory)
            throw error
        }
        rootDescriptor = directory
        listener = fd
        port = Int(UInt16(bigEndian: address.sin_port))
        let thread = Thread { [self] in acceptLoop(fd) }
        thread.name = "nrw.cyber.runfern.9p"
        thread.start()
        return port
    }

    func stop() {
        if listener >= 0 {
            shutdown(listener, SHUT_RDWR)
            close(listener)
            listener = -1
        }
        connections.withLock { open in
            open.forEach { shutdown($0, SHUT_RDWR) }
            open.removeAll()
        }
        // Sessions still running keep failing safely: the closed descriptor resolves nothing.
    }

    /// Whether `candidate` is the session token, without revealing through timing how much matched.
    func isToken(_ candidate: String) -> Bool {
        let expected = Array(token.utf8)
        let given = Array(candidate.utf8)
        var difference = UInt8(expected.count == given.count ? 0 : 1)
        for index in expected.indices {
            difference |= expected[index] ^ (index < given.count ? given[index] : 0)
        }
        return difference == 0
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else {
                if errno == EINTR { continue }
                return
            }
            let admitted = connections.withLock { open in
                guard open.count < Self.maximumConnections else { return false }
                open.append(client)
                return true
            }
            guard admitted else {
                close(client)
                continue
            }
            var noSigPipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            let thread = Thread { [self] in
                NinePSession(server: self, socket: client).run()
                connections.withLock { $0.removeAll { $0 == client } }
                close(client)
            }
            thread.name = "nrw.cyber.runfern.9p.session"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }
}

/// One client connection: reads requests, answers them in order.
private nonisolated final class NinePSession {
    private struct Fid {
        var components: [String]
        var descriptor: Int32 = -1
        var entries: [String]?
    }

    /// Enough for large builds; a client asking for more gets EMFILE.
    private static let maximumFids = 8192
    private static let maximumOpenFiles = 1024

    private let server: NinePServer
    private let socket: Int32
    private var fids: [UInt32: Fid] = [:]
    private var openFiles = 0
    private var msize = 512 * 1024
    private var attached = false
    private var rejected = false

    init(server: NinePServer, socket: Int32) {
        self.server = server
        self.socket = socket
    }

    func run() {
        defer { fids.values.forEach { if $0.descriptor >= 0 { close($0.descriptor) } } }
        while let message = readMessage() {
            var reader = NinePReader(message)
            guard let type = try? reader.u8(), let tag = try? reader.u16() else { return }
            let reply: Data
            do {
                var writer = NinePWriter()
                try handle(type, &reader, &writer)
                reply = NinePWriter.message(type: type + 1, tag: tag, body: writer.data)
            } catch let error as NinePError {
                var writer = NinePWriter()
                writer.u32(error.linuxCode)
                reply = NinePWriter.message(type: NinePType.rlerror, tag: tag, body: writer.data)
            } catch {
                return
            }
            guard send(reply), !rejected else { return }
        }
    }

    // MARK: Requests

    private func handle(_ type: UInt8, _ r: inout NinePReader, _ w: inout NinePWriter) throws {
        // Before a successful attach only version and attach are answered.
        guard attached || type == NinePType.tversion || type == NinePType.tattach else { throw NinePError.errno(EACCES) }
        switch type {
        case NinePType.tversion:
            msize = max(min(Int(try r.u32()), 512 * 1024), 4096)
            let version = try r.string()
            closeAll()
            w.u32(UInt32(msize))
            w.string(version.hasPrefix("9P2000.L") ? "9P2000.L" : "unknown")

        case NinePType.tattach:
            let fid = try r.u32()
            _ = try r.u32()            // afid
            _ = try r.string()         // uname
            let aname = try r.string()
            guard server.isToken(aname) else {
                rejected = true
                throw NinePError.errno(EACCES)
            }
            attached = true
            try addFid(fid, Fid(components: []))
            w.qid(try qid(for: []))

        case NinePType.tflush:
            _ = try r.u16()

        case NinePType.twalk:
            let fid = try fidValue(try r.u32())
            let newFid = try r.u32()
            let count = Int(try r.u16())
            guard count <= 16 else { throw NinePError.errno(EINVAL) }
            var components = fid.components
            var qids: [NinePQid] = []
            for index in 0..<count {
                let name = try r.string()
                var next = components
                if name == ".." {
                    if !next.isEmpty { next.removeLast() }
                } else if name != "." {
                    try validate(name)
                    next.append(name)
                }
                guard let walked = try? qid(for: next) else {
                    if index == 0 { throw NinePError.errno(ENOENT) }
                    break
                }
                qids.append(walked)
                components = next
            }
            if qids.count == count { try addFid(newFid, Fid(components: components)) }
            w.u16(UInt16(qids.count))
            qids.forEach { w.qid($0) }

        case NinePType.tgetattr:
            let fid = try fidValue(try r.u32())
            _ = try r.u64()            // request mask
            let info = try lstatInfo(fid.components)
            w.u64(0x3FFF)              // P9_GETATTR_ALL
            w.qid(NinePQid(info))
            w.u32(UInt32(info.st_mode))
            w.u32(server.owner.uid)
            w.u32(server.owner.gid)
            w.u64(UInt64(info.st_nlink))
            w.u64(UInt64(bitPattern: Int64(info.st_rdev)))
            w.u64(UInt64(info.st_size))
            w.u64(UInt64(info.st_blksize))
            w.u64(UInt64(info.st_blocks))
            for time in [info.st_atimespec, info.st_mtimespec, info.st_ctimespec, info.st_birthtimespec] {
                w.u64(UInt64(time.tv_sec))
                w.u64(UInt64(time.tv_nsec))
            }
            w.u64(0)                   // gen
            w.u64(0)                   // data version

        case NinePType.tsetattr:
            let fid = try fidValue(try r.u32())
            let valid = try r.u32()
            let mode = try r.u32()
            _ = try r.u32(); _ = try r.u32() // uid, gid: ownership stays with the app
            let size = try r.u64()
            let atime = (sec: try r.u64(), nsec: try r.u64())
            let mtime = (sec: try r.u64(), nsec: try r.u64())
            try withEntry(fid.components) { directory, name in
                // Permission bits only: no setuid, setgid, or sticky bits on the app's files.
                if valid & 0x1 != 0, fchmodat(directory, name, mode_t(mode & 0o777), AT_SYMLINK_NOFOLLOW) != 0 {
                    throw NinePError.current
                }
                if valid & 0x8 != 0 {
                    let fd = openat(directory, name, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
                    guard fd >= 0 else { throw NinePError.current }
                    defer { close(fd) }
                    guard ftruncate(fd, off_t(size)) == 0 else { throw NinePError.current }
                }
                if valid & 0x30 != 0 {
                    var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT))]
                    if valid & 0x10 != 0 {
                        times[0] = valid & 0x80 != 0 ? timespec(tv_sec: Int(atime.sec), tv_nsec: Int(atime.nsec))
                                                     : timespec(tv_sec: 0, tv_nsec: Int(UTIME_NOW))
                    }
                    if valid & 0x20 != 0 {
                        times[1] = valid & 0x100 != 0 ? timespec(tv_sec: Int(mtime.sec), tv_nsec: Int(mtime.nsec))
                                                      : timespec(tv_sec: 0, tv_nsec: Int(UTIME_NOW))
                    }
                    if utimensat(directory, name, times, AT_SYMLINK_NOFOLLOW) != 0 { throw NinePError.current }
                }
            }

        case NinePType.tlopen:
            let fidNumber = try r.u32()
            var fid = try fidValue(fidNumber)
            let flags = try r.u32()
            let info = try lstatInfo(fid.components)
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                fid.entries = nil
            case S_IFREG:
                guard fid.descriptor < 0 else { throw NinePError.errno(EBADF) }
                try reserveOpenFile()
                let fd = try withEntry(fid.components) { directory, name in
                    openat(directory, name, darwinFlags(flags) | O_NOFOLLOW | O_CLOEXEC)
                }
                guard fd >= 0 else {
                    openFiles -= 1
                    throw NinePError.current
                }
                fid.descriptor = fd
            default:
                // Links are read with readlink; devices, sockets, and pipes are never opened.
                throw NinePError.errno(ELOOP)
            }
            fids[fidNumber] = fid
            w.qid(NinePQid(info))
            w.u32(0)

        case NinePType.tlcreate:
            let fidNumber = try r.u32()
            let fid = try fidValue(fidNumber)
            let name = try r.string()
            let flags = try r.u32()
            let mode = try r.u32()
            _ = try r.u32()            // gid
            try validate(name)
            guard fid.descriptor < 0 else { throw NinePError.errno(EBADF) }
            try reserveOpenFile()
            let fd = try withDirectory(fid.components) { directory in
                openat(directory, name, darwinFlags(flags) | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(mode & 0o777))
            }
            guard fd >= 0 else {
                openFiles -= 1
                throw NinePError.current
            }
            let components = fid.components + [name]
            fids[fidNumber] = Fid(components: components, descriptor: fd)
            w.qid(try qid(for: components))
            w.u32(0)

        case NinePType.tread:
            let fid = try fidValue(try r.u32())
            let offset = try r.u64()
            let count = min(Int(try r.u32()), msize - 11)
            guard fid.descriptor >= 0, offset <= UInt64(Int64.max) else { throw NinePError.errno(EBADF) }
            var buffer = Data(count: count)
            let read = buffer.withUnsafeMutableBytes { pread(fid.descriptor, $0.baseAddress, count, off_t(offset)) }
            guard read >= 0 else { throw NinePError.current }
            w.u32(UInt32(read))
            w.bytes(buffer.prefix(read))

        case NinePType.twrite:
            let fid = try fidValue(try r.u32())
            let offset = try r.u64()
            let data = try r.bytes(Int(try r.u32()))
            guard fid.descriptor >= 0, offset <= UInt64(Int64.max) else { throw NinePError.errno(EBADF) }
            let written = data.withUnsafeBytes { pwrite(fid.descriptor, $0.baseAddress, data.count, off_t(offset)) }
            guard written >= 0 else { throw NinePError.current }
            w.u32(UInt32(written))

        case NinePType.treaddir:
            let fidNumber = try r.u32()
            var fid = try fidValue(fidNumber)
            let offset = Int(try r.u64())
            let count = min(Int(try r.u32()), msize - 11)
            if fid.entries == nil || offset == 0 {
                fid.entries = [".", ".."] + (try listDirectory(fid.components)).sorted()
                fids[fidNumber] = fid
            }
            var body = NinePWriter()
            for (index, name) in (fid.entries ?? []).enumerated() where index >= offset {
                let target = name == "." ? fid.components : name == ".." ? Array(fid.components.dropLast()) : fid.components + [name]
                guard let info = try? lstatInfo(target) else { continue }
                var entry = NinePWriter()
                let entryQid = NinePQid(info)
                entry.qid(entryQid)
                entry.u64(UInt64(index + 1))
                entry.u8(entryQid.type == NinePQid.directory ? 4 : entryQid.type == NinePQid.symlink ? 10 : 8)
                entry.string(name)
                guard body.data.count + entry.data.count <= count - 4 else { break }
                body.bytes(entry.data)
            }
            w.u32(UInt32(body.data.count))
            w.bytes(body.data)

        case NinePType.tclunk:
            let fidNumber = try r.u32()
            if let fid = fids.removeValue(forKey: fidNumber) { closeDescriptor(of: fid) }

        case NinePType.tremove:
            let fidNumber = try r.u32()
            let fid = try fidValue(fidNumber)
            closeDescriptor(of: fid)
            fids[fidNumber] = nil
            try removeItem(fid.components)

        case NinePType.tmkdir:
            let fid = try fidValue(try r.u32())
            let name = try r.string()
            let mode = try r.u32()
            _ = try r.u32()
            try validate(name)
            try withDirectory(fid.components) { directory in
                guard mkdirat(directory, name, mode_t(mode & 0o777)) == 0 else { throw NinePError.current }
            }
            w.qid(try qid(for: fid.components + [name]))

        case NinePType.tunlinkat:
            let fid = try fidValue(try r.u32())
            let name = try r.string()
            _ = try r.u32()            // flags; the item's type decides
            try validate(name)
            try removeItem(fid.components + [name])

        case NinePType.trenameat:
            let old = try fidValue(try r.u32())
            let oldName = try r.string()
            let new = try fidValue(try r.u32())
            let newName = try r.string()
            try validate(oldName)
            try validate(newName)
            try withDirectory(old.components) { oldDirectory in
                try withDirectory(new.components) { newDirectory in
                    guard renameat(oldDirectory, oldName, newDirectory, newName) == 0 else { throw NinePError.current }
                }
            }

        case NinePType.trename:
            let fidNumber = try r.u32()
            var fid = try fidValue(fidNumber)
            let directory = try fidValue(try r.u32())
            let name = try r.string()
            try validate(name)
            try withEntry(fid.components) { oldDirectory, oldName in
                try withDirectory(directory.components) { newDirectory in
                    guard renameat(oldDirectory, oldName, newDirectory, name) == 0 else { throw NinePError.current }
                }
            }
            fid.components = directory.components + [name]
            fids[fidNumber] = fid

        case NinePType.tsymlink:
            let fid = try fidValue(try r.u32())
            let name = try r.string()
            let target = try r.string()
            _ = try r.u32()
            try validate(name)
            guard !target.isEmpty, !target.contains("\0"), target.utf8.count < Int(PATH_MAX) else {
                throw NinePError.errno(EINVAL)
            }
            // Any target is fine: the server stores the link but never follows it.
            try withDirectory(fid.components) { directory in
                guard symlinkat(target, directory, name) == 0 else { throw NinePError.current }
            }
            w.qid(try qid(for: fid.components + [name]))

        case NinePType.treadlink:
            let fid = try fidValue(try r.u32())
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let length = try withEntry(fid.components) { directory, name in
                readlinkat(directory, name, &buffer, Int(PATH_MAX))
            }
            guard length >= 0 else { throw NinePError.current }
            w.string(String(decoding: buffer.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self))

        case NinePType.tlink:
            let directory = try fidValue(try r.u32())
            let fid = try fidValue(try r.u32())
            let name = try r.string()
            try validate(name)
            try withEntry(fid.components) { sourceDirectory, sourceName in
                try withDirectory(directory.components) { targetDirectory in
                    // Without AT_SYMLINK_FOLLOW a link is linked as itself, never its target.
                    guard linkat(sourceDirectory, sourceName, targetDirectory, name, 0) == 0 else { throw NinePError.current }
                }
            }

        case NinePType.tstatfs:
            _ = try fidValue(try r.u32())
            var info = statfs()
            guard fstatfs(server.rootDescriptor, &info) == 0 else { throw NinePError.current }
            w.u32(0x01021997)           // V9FS_MAGIC
            w.u32(info.f_bsize)
            w.u64(info.f_blocks)
            w.u64(info.f_bfree)
            w.u64(info.f_bavail)
            w.u64(info.f_files)
            w.u64(info.f_ffree)
            w.u64(0)
            w.u32(255)

        case NinePType.tfsync:
            let fid = try fidValue(try r.u32())
            if fid.descriptor >= 0 { fsync(fid.descriptor) }

        case NinePType.tlock:
            w.u8(0)                     // P9_LOCK_SUCCESS: locks are advisory and per client

        case NinePType.tgetlock:
            _ = try r.u32()
            _ = try r.u8()
            let start = try r.u64()
            let length = try r.u64()
            let process = try r.u32()
            let client = try r.string()
            w.u8(2)                     // F_UNLCK: nothing holds the range
            w.u64(start)
            w.u64(length)
            w.u32(process)
            w.string(client)

        case NinePType.txattrwalk, NinePType.txattrcreate, NinePType.tmknod:
            throw NinePError.errno(ENOTSUP)

        default:
            throw NinePError.errno(ENOSYS)
        }
    }

    // MARK: Fids

    private func fidValue(_ number: UInt32) throws -> Fid {
        guard attached, let fid = fids[number] else { throw NinePError.errno(EBADF) }
        return fid
    }

    private func addFid(_ number: UInt32, _ fid: Fid) throws {
        if let existing = fids[number] {
            closeDescriptor(of: existing)
        } else if fids.count >= Self.maximumFids {
            throw NinePError.errno(EMFILE)
        }
        fids[number] = fid
    }

    private func reserveOpenFile() throws {
        guard openFiles < Self.maximumOpenFiles else { throw NinePError.errno(EMFILE) }
        openFiles += 1
    }

    private func closeDescriptor(of fid: Fid) {
        guard fid.descriptor >= 0 else { return }
        close(fid.descriptor)
        openFiles -= 1
    }

    private func closeAll() {
        fids.values.forEach(closeDescriptor(of:))
        fids.removeAll()
    }

    // MARK: Paths

    /// Names come from the client; they must stay inside their directory.
    private func validate(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0"),
              name.utf8.count <= Int(NAME_MAX) else {
            throw NinePError.errno(EINVAL)
        }
    }

    /// Runs `body` with a descriptor of the directory at `components`, opened one level at a time
    /// from the folder without following links (a link anywhere in the path fails with ENOTDIR
    /// or ELOOP).
    private func withDirectory<T>(_ components: [String], _ body: (Int32) throws -> T) throws -> T {
        var current = server.rootDescriptor
        guard current >= 0 else { throw NinePError.errno(EIO) }
        defer { if current != server.rootDescriptor { close(current) } }
        for name in components {
            let next = openat(current, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw NinePError.current }
            if current != server.rootDescriptor { close(current) }
            current = next
        }
        return try body(current)
    }

    /// Runs `body` with the entry at `components` as its directory descriptor and name; the folder
    /// itself is passed as "." of its own descriptor.
    private func withEntry<T>(_ components: [String], _ body: (Int32, String) throws -> T) throws -> T {
        guard let name = components.last else {
            return try withDirectory([]) { try body($0, ".") }
        }
        return try withDirectory(Array(components.dropLast())) { try body($0, name) }
    }

    private func lstatInfo(_ components: [String]) throws -> stat {
        var info = stat()
        try withEntry(components) { directory, name in
            guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw NinePError.current }
        }
        return info
    }

    private func qid(for components: [String]) throws -> NinePQid {
        NinePQid(try lstatInfo(components))
    }

    private func listDirectory(_ components: [String]) throws -> [String] {
        try withDirectory(components) { directory in
            let fd = openat(directory, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard fd >= 0, let stream = fdopendir(fd) else {
                if fd >= 0 { close(fd) }
                throw NinePError.current
            }
            defer { closedir(stream) }
            var names: [String] = []
            while let entry = readdir(stream) {
                let name = withUnsafeBytes(of: entry.pointee.d_name) {
                    String(decoding: $0.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
                }
                if name != "." && name != ".." { names.append(name) }
            }
            return names
        }
    }

    private func removeItem(_ components: [String]) throws {
        guard !components.isEmpty else { throw NinePError.errno(EBUSY) }
        let info = try lstatInfo(components)
        try withEntry(components) { directory, name in
            let flags = info.st_mode & S_IFMT == S_IFDIR ? AT_REMOVEDIR : 0
            guard unlinkat(directory, name, flags) == 0 else { throw NinePError.current }
        }
    }

    /// Linux open flags to Darwin ones.
    private func darwinFlags(_ linux: UInt32) -> Int32 {
        var flags: Int32
        switch linux & 0o3 {
        case 1: flags = O_WRONLY
        case 2: flags = O_RDWR
        default: flags = O_RDONLY
        }
        if linux & 0o100 != 0 { flags |= O_CREAT }
        if linux & 0o200 != 0 { flags |= O_EXCL }
        if linux & 0o1000 != 0 { flags |= O_TRUNC }
        if linux & 0o2000 != 0 { flags |= O_APPEND }
        return flags
    }

    // MARK: Framing

    private func readMessage() -> Data? {
        guard let header = readExactly(4) else { return nil }
        let size = header.reversed().reduce(0) { $0 << 8 | Int($1) }
        guard size >= 7, size <= msize + 64 else { return nil }
        return readExactly(size - 4)
    }

    private func readExactly(_ count: Int) -> Data? {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let read = data.withUnsafeMutableBytes { Darwin.read(socket, $0.baseAddress! + offset, count - offset) }
            if read < 0, errno == EINTR { continue }
            guard read > 0 else { return nil }
            offset += read
        }
        return data
    }

    private func send(_ data: Data) -> Bool {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(socket, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }
}
