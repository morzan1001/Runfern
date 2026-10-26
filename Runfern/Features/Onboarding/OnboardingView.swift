import SwiftUI

/// First launch (Plan 2.1, SET03): local operation, storage needs, and the difference between project and environment.
/// Permissions are only requested once a storage location is chosen.
struct OnboardingView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(Provisioner.self) private var provisioner

    let finish: (_ createOwnProject: Bool) -> Void
    let createdSample: (Project) -> Void

    @State private var errorMessage: String?

    private var sampleImage: BaseImage { Catalog.baseImages[0] }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Welcome to Runfern")
                        .font(.largeTitle.bold())
                    point("ipad", "Everything Local",
                          "VS Code, Linux, and your programs run on this iPad. No account required.")
                    point("square.stack.3d.up", "Project and Environment",
                          "Each project gets its own Linux environment. Resetting it never touches your files.")
                    point("internaldrive", "Storage",
                          "A Linux base needs about \(sampleImage.downloadSizeBytes.formattedBytes) once, plus the tools of each project.")
                    point("wifi", "Internet Only for Downloads",
                          "Once set up, projects work offline.")
                    if !DeviceProfile.current.meetsTarget {
                        point("exclamationmark.triangle", "Limited Device",
                              "Runfern is designed for iPads with an M-series chip.")
                    }
                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: 560, alignment: .leading)
                .padding(32)
                .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 12) {
                    Button(action: createSample) {
                        Text("Create Sample Project").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button { finish(true) } label: {
                        Text("Create Your Own Project").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button("Later") { finish(false) }
                }
                .controlSize(.large)
                .frame(maxWidth: 560)
                .padding()
            }
        }
    }

    private func point(_ systemImage: String, _ title: LocalizedStringKey, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func createSample() {
        do {
            let project = try store.createProject(
                name: String(localized: "Python Sample"), details: String(localized: "A small starter project to try things out"),
                source: .pythonStarter, baseImage: sampleImage,
                toolchains: Catalog.toolchains(for: sampleImage), binding: .appInternal()
            )
            provisioner.start(project)
            createdSample(project)
            finish(false)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
