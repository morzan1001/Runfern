import SwiftUI
import UniformTypeIdentifiers

/// Entry point of the app: the project overview (PRJ01, PRJ02, PRJ05, RUN04).
struct ProjectOverviewView: View {
    /// Raw values are persisted in user defaults and must stay stable.
    enum SortOrder: String, CaseIterable {
        case lastUsed
        case name

        var title: LocalizedStringKey {
            switch self {
            case .lastUsed: "Last Used"
            case .name: "Name"
            }
        }
    }

    @Environment(ProjectStore.self) private var store
    @Environment(RuntimeCoordinator.self) private var runtime
    @Environment(SyncCenter.self) private var sync
    @Environment(Connectivity.self) private var connectivity

    @AppStorage("didCompleteOnboarding") private var didCompleteOnboarding = false
    @AppStorage("projectSortOrder") private var sortOrder = SortOrder.lastUsed

    @State private var showingNewProject = false
    /// Import starts with the document picker; the sheet opens only once there is a package to check.
    @State private var showingImport = false
    @State private var importArchive: ImportArchive?
    @State private var showingSettings = false
    // Per window, so each window comes back to its own project and list after iPadOS ends the app.
    @SceneStorage("showingArchive") private var showingArchive = false
    @SceneStorage("selectedProject") private var selectedProjectID: String?
    @State private var ideProjectID: UUID?
    @State private var projectToRemove: Project?
    @State private var projectToDuplicate: Project?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @State private var searchText = ""
    @State private var wantsNewProjectAfterOnboarding = false

    /// A package picked for import; presenting it opens the import sheet.
    private struct ImportArchive: Identifiable {
        let id = UUID()
        let url: URL
    }

    private var selection: UUID? {
        get { selectedProjectID.flatMap(UUID.init(uuidString:)) }
        nonmutating set { selectedProjectID = newValue?.uuidString }
    }

    /// The selected project left the visible list (archived, restored, or Show Archive toggled).
    private var selectionIsHidden: Bool {
        selection.flatMap { store.project(id: $0) }.map { $0.isArchived != showingArchive } ?? false
    }

    /// Selects a project that a sheet just created, switching to the list it belongs to.
    private func show(_ project: Project) {
        if project.isArchived != showingArchive { showingArchive = project.isArchived }
        selection = project.id
    }

    private var visibleProjects: [Project] {
        let source = showingArchive ? store.archivedProjects : store.activeProjects
        let filtered = searchText.isEmpty ? source : source.filter { $0.name.localizedStandardContains(searchText) }
        switch sortOrder {
        case .name: return filtered.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .lastUsed: return filtered.sorted { ($0.lastOpenedAt ?? $0.createdAt) > ($1.lastOpenedAt ?? $1.createdAt) }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: Binding<UUID?>(get: { selection }, set: { selection = $0 })) {
                if let activeID = runtime.activeProjectID, let active = store.project(id: activeID) {
                    Section("Active Session") {
                        Button {
                            ideProjectID = active.id
                        } label: {
                            Label("Back to “\(active.name)”", systemImage: "arrow.uturn.forward.circle.fill")
                        }
                    }
                }
                Section(showingArchive ? String(localized: "Archive") : String(localized: "Projects")) {
                    ForEach(visibleProjects) { project in
                        ProjectRow(project: project, isActive: runtime.activeProjectID == project.id)
                            .tag(project.id)
                            .swipeActions(allowsFullSwipe: false) {
                                // Not `role: .destructive`: that makes the list drop the row right away,
                                // while removal only starts after the confirmation sheet.
                                Button("Remove", systemImage: "trash") { projectToRemove = project }
                                    .tint(.red)
                                ArchiveButton(project: project)
                                    .tint(.indigo)
                            }
                            .contextMenu {
                                if supportsMultipleWindows {
                                    Button("Open in New Window", systemImage: "macwindow.badge.plus") {
                                        openWindow(id: ProjectWindow.id, value: project.id)
                                    }
                                }
                                Button("Duplicate…", systemImage: "plus.square.on.square") { projectToDuplicate = project }
                                Divider()
                                ArchiveButton(project: project)
                                Button("Remove…", systemImage: "trash", role: .destructive) { projectToRemove = project }
                            }
                    }
                }
            }
            .navigationTitle("Runfern")
            .searchable(text: $searchText, prompt: "Search Projects")
            .overlay {
                if visibleProjects.isEmpty {
                    if !searchText.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                    } else if showingArchive {
                        ContentUnavailableView("No Archived Projects", systemImage: "archivebox")
                    } else {
                        ContentUnavailableView {
                            Label("No Projects Yet", systemImage: "folder.badge.plus")
                        } description: {
                            Text("Create a project or import one.")
                        } actions: {
                            Button("New Project") { showingNewProject = true }.buttonStyle(.borderedProminent)
                            Button("Import Project…") { showingImport = true }
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    // Tapping creates a project; holding offers importing one as well.
                    Menu {
                        Button("New Project", systemImage: "plus") { showingNewProject = true }
                        Button("Import Project…", systemImage: "square.and.arrow.down") { showingImport = true }
                    } label: {
                        Label("New Project", systemImage: "plus")
                    } primaryAction: {
                        showingNewProject = true
                    }
                }
                // Straight in the "…" menu, like Files and Notes; the picker's submenu shows the current order.
                ToolbarItemGroup(placement: .secondaryAction) {
                    Picker("Sort By", systemImage: "arrow.up.arrow.down", selection: $sortOrder) {
                        ForEach(SortOrder.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                    Toggle("Show Archive", systemImage: "archivebox", isOn: $showingArchive)
                    Button("Settings", systemImage: "gearshape") { showingSettings = true }
                }
            }
            .safeAreaInset(edge: .bottom) { statusBanners }
        } detail: {
            if let id = selection, let project = store.project(id: id) {
                // Own stack, so screens pushed from the details (for example extensions) get a back button.
                NavigationStack {
                    ProjectDetailView(project: project, requestRemoval: { projectToRemove = project }) {
                        ideProjectID = project.id
                    }
                }
                .id(project.id)
            } else {
                ContentUnavailableView("No Project Selected", systemImage: "sidebar.left",
                                       description: Text("Select a project in the sidebar."))
            }
        }
        // The detail always matches the sidebar: a project that leaves the visible list is deselected,
        // as in Mail when a message is archived.
        .onChange(of: selectionIsHidden) { _, hidden in
            if hidden { selection = nil }
        }
        // The menu bar reaches the overview from anywhere in the window, also with the sidebar hidden.
        .focusedSceneValue(\.overviewActions, menuActions)
        .fileImporter(isPresented: $showingImport, allowedContentTypes: [.zip]) { result in
            if case .success(let url) = result { importArchive = ImportArchive(url: url) }
        }
        .sheet(item: $importArchive) { archive in
            ImportProjectView(archive: archive.url) { show($0) }
        }
        .sheet(isPresented: $showingNewProject) {
            NewProjectView { show($0) }
        }
        .sheet(isPresented: $showingSettings) {
            // Settings has several levels of navigation; a page-sized sheet keeps them readable.
            SettingsView()
                .presentationSizing(.page)
        }
        .sheet(isPresented: Binding(get: { !didCompleteOnboarding }, set: { if !$0 { didCompleteOnboarding = true } }),
               onDismiss: { if wantsNewProjectAfterOnboarding { showingNewProject = true } }) {
            OnboardingView { createOwnProject in
                wantsNewProjectAfterOnboarding = createOwnProject
                didCompleteOnboarding = true
            } createdSample: { show($0) }
            .interactiveDismissDisabled()
        }
        .fullScreenCover(item: $ideProjectID) { id in
            if let project = store.project(id: id) {
                IDEView(project: project) { ideProjectID = nil }
            } else {
                // Removed elsewhere (for example in another window): never leave an empty cover.
                Color.clear.onAppear { ideProjectID = nil }
            }
        }
        .sheet(item: $projectToDuplicate) { project in
            DuplicateProjectView(project: project) { show($0) }
        }
        .sheet(item: $projectToRemove) { project in
            RemoveProjectView(project: project) {
                if selection == project.id { selection = nil }
            }
        }
        .task { await store.refreshAccess() }
    }

    /// While a sheet or the editor covers the overview, the menu commands are disabled, so they don't
    /// present a second modal and their keys reach VS Code.
    private var isPresentingModal: Bool {
        ideProjectID != nil || showingNewProject || showingImport || importArchive != nil || showingSettings
            || projectToRemove != nil || projectToDuplicate != nil || !didCompleteOnboarding
    }

    /// What the menu bar's File, Runfern and Project menus can do in this window.
    private var menuActions: OverviewActions? {
        guard !isPresentingModal else { return nil }
        var returnToEditor: (() -> Void)?
        if let activeID = runtime.activeProjectID, store.project(id: activeID) != nil {
            returnToEditor = { ideProjectID = activeID }
        }
        return OverviewActions(newProject: { showingNewProject = true },
                               importProject: { showingImport = true },
                               showSettings: { showingSettings = true },
                               returnToEditor: returnToEditor)
    }

    @ViewBuilder
    private var statusBanners: some View {
        VStack(spacing: 0) {
            if !connectivity.isOnline {
                Banner(text: "Offline – local projects, terminal, and commits remain available.", systemImage: "wifi.slash", tint: .secondary)
            }
            if !store.recoveredEnvironmentIDs.isEmpty {
                Banner(text: "Runfern quit unexpectedly. Affected environments are marked for review; saved project files are intact.",
                       systemImage: "arrow.counterclockwise.circle", tint: .orange) { store.acknowledgeRecovery() }
            }
            if let message = store.lastSaveError {
                Banner(text: "Saving failed: \(message)", systemImage: "externaldrive.badge.exclamationmark", tint: .red)
            }
        }
    }
}
