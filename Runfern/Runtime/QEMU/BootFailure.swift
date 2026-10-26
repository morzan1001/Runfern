import Foundation

/// Recognizes a guest that stopped booting, so the app fails at once instead of waiting for the
/// agent until the boot timeout.
nonisolated enum BootFailure {
    /// Console output after which Linux never reaches the agent on its own.
    private static let markers = [
        "Kernel panic",
        "(initramfs)",
        "requires a manual fsck",
        "Give root password for maintenance",
        "You are in emergency mode",
    ]

    /// The first failure marker in the end of the guest console, if any.
    static func detect(in console: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: console) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 16_384 ? size - 16_384 : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        return markers.first { text.contains($0) }
    }
}
