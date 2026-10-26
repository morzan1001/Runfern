import SwiftUI

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
    @State private var showingImport = false
    @State private var showingSettings = false
    @State private var showingArchive = false
    @State private var selection: UUID?
    @State private var ideProjectID: UUID?
    @State private var projectToRemove: Project?
    @State private var projectToDuplicate: Project?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @State private var searchText = ""
    @State private var wantsNewProjectAfterOnboarding = false

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
            List(selection: $selection) {
                if let activeID = runtime.activeProjectID, let active = store.project(id: activeID) {
                    Section("Active Session") {
                        Button {
                            ideProjectID = active.id
                        } label: {
                            Label("Back to “\(active.name)”", systemImage: "arrow.uturn.forward.circle.fill")
                        }
                        .keyboardShortcut(.return, modifiers: [.command, .shift])
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
                                Button(project.isArchived ? String(localized: "Restore") : String(localized: "action.archive", defaultValue: "Archive")) {
                                    store.setArchived(!project.isArchived, for: project)
                                }
                                .tint(.indigo)
                            }
                            .contextMenu {
                                if supportsMultipleWindows {
                                    Button("Open in New Window", systemImage: "macwindow.badge.plus") {
                                        openWindow(id: ProjectWindow.id, value: project.id)
                                    }
                                }
                                Button("Duplicate…", systemImage: "plus.square.on.square") { projectToDuplicate = project }
                                Button(project.isArchived ? String(localized: "Restore") : String(localized: "action.archive", defaultValue: "Archive"), systemImage: "archivebox") {
                                    store.setArchived(!project.isArchived, for: project)
                                }
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
                            Button("New Project") { showingNewProject = true }.buttonStyle(.glassProminent)
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
                    .keyboardShortcut("n", modifiers: .command)
                }
                ToolbarItem(placement: .secondaryAction) {
                    Menu("View Options", systemImage: "line.3.horizontal.decrease.circle") {
                        Picker("Sort By", selection: $sortOrder) {
                            ForEach(SortOrder.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        Toggle("Show Archive", systemImage: "archivebox", isOn: $showingArchive)
                    }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button("Settings", systemImage: "gearshape") { showingSettings = true }
                        .keyboardShortcut(",", modifiers: .command)
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
        .sheet(isPresented: $showingImport) {
            ImportProjectView { selection = $0.id }
        }
        .sheet(isPresented: $showingNewProject) {
            NewProjectView { selection = $0.id }
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
            } createdSample: { selection = $0.id }
            .interactiveDismissDisabled()
        }
        .fullScreenCover(item: $ideProjectID) { id in
            if let project = store.project(id: id) {
                IDEView(project: project) { ideProjectID = nil }
            }
        }
        .sheet(item: $projectToDuplicate) { project in
            DuplicateProjectView(project: project) { selection = $0.id }
        }
        .sheet(item: $projectToRemove) { project in
            RemoveProjectView(project: project) {
                if selection == project.id { selection = nil }
            }
        }
        .task { store.refreshAccess() }
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
