import SwiftUI

/// Simple editor on the local working copy. It does not replace code-server; it makes the storage
/// contract verifiable: edit → saved locally → synced with the folder (DAT03, ADR09).
struct WorkspaceEditorView: View {
    struct FileNode: Identifiable, Hashable {
        let id: String          // relative path
        let name: String
        let isDirectory: Bool
        var children: [FileNode]?
    }

    @Environment(SyncCenter.self) private var sync

    let project: Project
    let binding: WorkspaceBinding
    let close: () -> Void

    @State private var tree: [FileNode] = []
    @State private var selection: String?
    @State private var text = ""
    @State private var savedText = ""
    @State private var isBinary = false
    @State private var saveError: String?
    @State private var changedOnDisk = false
    @State private var newFileName = ""
    @State private var creatingFile = false
    @State private var pathToDelete: String?
    @State private var showingPreview = false
    @State private var files: WorkspaceFiles?

    private var root: URL { files?.url ?? AppPaths.workingCopy(binding.id) }
    private var isDirty: Bool { text != savedText }

    var body: some View {
        NavigationSplitView {
            List(tree, children: \.children, selection: $selection) { node in
                Label(node.name, systemImage: node.isDirectory ? "folder" : "doc.text")
                    .contextMenu {
                        if !node.isDirectory {
                            Button("Delete", systemImage: "trash", role: .destructive) { pathToDelete = node.id }
                        }
                    }
            }
            .navigationTitle(project.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Overview", systemImage: "square.grid.2x2") {
                        saveIfNeeded()
                        close()
                    }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Preview", systemImage: "safari") { showingPreview = true }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("New File", systemImage: "doc.badge.plus") { creatingFile = true }
                        .keyboardShortcut("n", modifiers: [.command, .shift])
                }
            }
            .refreshable { await syncNow() }
            // Files dropped from other apps are copied into the project; nothing is overwritten (UX03).
            .dropDestination(for: URL.self) { urls, _ in
                importDroppedItems(urls)
                return !urls.isEmpty
            }
        } detail: {
            editor
        }
        .task {
            files = try? WorkspaceFiles(binding)
            reloadTree()
        }
        .sheet(isPresented: $showingPreview) { DevServerPreviewView() }
        .onChange(of: selection) { oldValue, newValue in
            if let oldValue { save(oldValue, interactive: false) }
            load(newValue)
        }
        .onChange(of: sync.status(for: binding).lastSyncedAt) {
            // External changes may have arrived with a sync.
            reloadTree()
            if !isDirty { load(selection) } else { detectExternalChange() }
        }
        .task(id: text) {
            // Continuous saving shortly after the last keystroke (DAT03).
            guard isDirty else { return }
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            saveIfNeeded()
        }
        .alert("New File", isPresented: $creatingFile) {
            TextField("Path, e.g. src/app.py", text: $newFileName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Create", action: createFile)
            Button("Cancel", role: .cancel) { newFileName = "" }
        }
        .confirmationDialog("Delete File?", isPresented: Binding(get: { pathToDelete != nil }, set: { if !$0 { pathToDelete = nil } }),
                            presenting: pathToDelete) { path in
            Button("Delete “\(path)”", role: .destructive) { delete(path) }
        } message: { _ in
            Text("The deletion is also applied to the project folder with the next sync.")
        }
        .alert("File Changed Elsewhere", isPresented: $changedOnDisk) {
            Button("Save My Version") { forceSave() }
            Button("Load Other Version", role: .destructive) { load(selection) }
        } message: {
            Text("While you were editing, a sync changed this file. Which version should be kept?")
        }
    }

    @ViewBuilder
    private var editor: some View {
        Group {
            if let selection, !isBinary {
                TextEditor(text: $text)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .contentMargins(.horizontal, 12, for: .scrollContent)
                    .navigationTitle(selection)
            } else if isBinary {
                ContentUnavailableView("Not a Text File", systemImage: "doc.questionmark",
                                       description: Text("This file can't be shown in the built-in editor."))
            } else {
                ContentUnavailableView("No File Open", systemImage: "doc.text",
                                       description: Text("Select a file in the sidebar."))
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { statusBar }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Save", systemImage: "square.and.arrow.down") { saveIfNeeded() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!isDirty)
            }
        }
    }

    private var statusBar: some View {
        let status = sync.status(for: binding)
        return HStack(spacing: 12) {
            if let saveError {
                Label("Not saved: \(saveError)", systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            } else if isDirty {
                Label("Unsaved Changes", systemImage: "pencil")
            } else if binding.storageMode == .mountedFolder {
                Label("Saved to Folder", systemImage: "checkmark.circle")
            } else {
                Label("Saved Locally", systemImage: "internaldrive")
            }
            Spacer()
            if binding.storageMode == .localFolder {
                switch status.phase {
                case .syncing: Label("Syncing…", systemImage: "arrow.triangle.2.circlepath")
                case .unreachable: Label("Folder Not Reachable", systemImage: "externaldrive.badge.xmark").foregroundStyle(.orange)
                case .failed: Label("Sync Failed", systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                case .idle:
                    if !status.conflicts.isEmpty {
                        Label("\(status.conflicts.count) conflicts", systemImage: "exclamationmark.2").foregroundStyle(.orange)
                    } else if status.pendingLocalChanges > 0 {
                        Label("\(status.pendingLocalChanges) pending", systemImage: "clock.arrow.circlepath")
                    } else {
                        Label("Saved to Folder", systemImage: "checkmark.circle")
                    }
                }
            }
            Text("Simulated Runtime").foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(8)
        .background(.bar)
    }

    // MARK: Files

    private func reloadTree() {
        tree = Self.buildTree(at: root, relativeTo: "")
    }

    private static func buildTree(at url: URL, relativeTo prefix: String) -> [FileNode] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: url.path(percentEncoded: false)) else { return [] }
        let nodes = names
            .filter { !DirectoryScanner.isExcluded($0) && $0 != ".git" }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { name in
                let child = url.appending(path: name)
                let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
                var isDirectory: ObjCBool = false
                fm.fileExists(atPath: child.path(percentEncoded: false), isDirectory: &isDirectory)
                return FileNode(id: path, name: name, isDirectory: isDirectory.boolValue,
                                children: isDirectory.boolValue ? buildTree(at: child, relativeTo: path) : nil)
            }
        // Folders first, alphabetical within both groups.
        return nodes.filter(\.isDirectory) + nodes.filter { !$0.isDirectory }
    }

    private func load(_ path: String?) {
        saveError = nil
        guard let path, let data = try? Data(contentsOf: root.appending(path: path)) else {
            text = ""; savedText = ""; isBinary = false
            return
        }
        if let string = String(data: data, encoding: .utf8) {
            text = string; savedText = string; isBinary = false
        } else {
            text = ""; savedText = ""; isBinary = true
        }
    }

    private func saveIfNeeded() {
        guard let selection, isDirty else { return }
        save(selection, interactive: true)
    }

    /// Never silently overwrite a version that arrived through a sync in the meantime: interactively we ask,
    /// and when switching files the user's edits go into an additional file.
    private func save(_ path: String, interactive: Bool) {
        guard !isBinary, text != savedText else { return }
        let url = root.appending(path: path)
        if let current = try? String(contentsOf: url, encoding: .utf8), current != savedText {
            if interactive {
                changedOnDisk = true
            } else {
                write(text, to: root.appending(path: SyncEngine.alternateName(for: path, in: root, label: "Runfern")))
                reloadTree()
            }
            return
        }
        write(text, to: url)
    }

    private func forceSave() {
        guard let selection else { return }
        write(text, to: root.appending(path: selection))
    }

    /// Atomic write; only afterwards does the change count as saved locally.
    private func write(_ content: String, to url: URL) {
        do {
            try Data(content.utf8).write(to: url, options: .atomic)
            savedText = content
            saveError = nil
            Task { await sync.sync(binding) }
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func detectExternalChange() {
        guard let selection, let current = try? String(contentsOf: root.appending(path: selection), encoding: .utf8) else { return }
        if current != savedText { changedOnDisk = true }
    }

    private func createFile() {
        let path = newFileName.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        newFileName = ""
        guard !path.isEmpty, !path.split(separator: "/").contains("..") else { return }
        let url = root.appending(path: path)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url, options: .withoutOverwriting)
            reloadTree()
            selection = path
            Task { await sync.sync(binding) }
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func delete(_ path: String) {
        do {
            try FileManager.default.removeItem(at: root.appending(path: path))
            if selection == path { selection = nil }
            reloadTree()
            Task { await sync.sync(binding) }
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func importDroppedItems(_ urls: [URL]) {
        let fm = FileManager.default
        for url in urls {
            let didStart = url.startAccessingSecurityScopedResource()
            defer { if didStart { url.stopAccessingSecurityScopedResource() } }
            var name = url.lastPathComponent
            if fm.fileExists(atPath: root.appending(path: name).path(percentEncoded: false)) {
                name = SyncEngine.alternateName(for: name, in: root, label: String(localized: "dropped"))
            }
            do {
                try fm.copyItem(at: url, to: root.appending(path: name))
            } catch {
                saveError = error.localizedDescription
            }
        }
        reloadTree()
        Task { await sync.sync(binding) }
    }

    private func syncNow() async {
        saveIfNeeded()
        await sync.sync(binding)
    }
}
