#if DEBUG
import SwiftUI

struct ScreenshotView: View {
    enum Screen: String {
        case project
        case newProject = "new-project"
    }

    static var requested: Screen? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-screenshot"), arguments.indices.contains(index + 1) else {
            return nil
        }
        return Screen(rawValue: arguments[index + 1])
    }

    let screen: Screen
    @State private var fixture = ProjectPreviewFixture()

    var body: some View {
        switch screen {
        case .newProject:
            fixture.environment(NewProjectView { _ in })
        case .project:
            SampleProjectView(fixture: fixture)
        }
    }

    private struct SampleProjectView: View {
        let fixture: ProjectPreviewFixture
        @State private var project: Project

        init(fixture: ProjectPreviewFixture) {
            self.fixture = fixture
            _project = State(initialValue: fixture.project(.ready))
        }

        var body: some View {
            fixture.environment(NavigationStack {
                ProjectDetailView(project: project) {}
            })
        }
    }
}
#endif
