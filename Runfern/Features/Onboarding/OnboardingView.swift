import SwiftUI

/// First launch (Plan 2.1, SET03): local operation, storage needs, and the difference between project and environment.
/// Permissions are only requested once a storage location is chosen.
struct OnboardingView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(Provisioner.self) private var provisioner

    let finish: (_ createOwnProject: Bool) -> Void
    let createdSample: (Project) -> Void

    /// A failed “Create Sample Project”, shown as an alert (A7).
    @State private var errorMessage: String?
    /// The icon column grows with the `.title2` symbols it holds.
    @ScaledMetric(relativeTo: .title2) private var iconWidth: CGFloat = 36

    private var sampleImage: BaseImage { Catalog.baseImages[0] }
    /// Only Python: the sample is a small Python project, and the base supports many more languages.
    private var sampleToolchains: [ToolchainProfile] { Catalog.toolchain(id: "python-3").map { [$0] } ?? [] }
    private var sampleDownload: Int64 {
        sampleImage.downloadSizeBytes + sampleToolchains.reduce(0) { $0 + $1.estimatedSizeBytes }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Welcome to Runfern")
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                point("ipad", "Everything Local",
                      "VS Code, Linux, and your programs run on this iPad. No account required.")
                point("square.stack.3d.up", "Project and Environment",
                      "Each project gets its own Linux environment. Resetting it never touches your files.")
                point("internaldrive", "Storage",
                      "A Linux base needs about \(sampleImage.downloadSizeBytes.formattedBytes) once, plus the tools of each project.")
                point("wifi", "Internet Only for Downloads",
                      "Once set up, projects work offline.")
                if !DeviceProfile.current.meetsTarget {
                    point("exclamationmark.triangle.fill", "Limited Device",
                          "Runfern is designed for iPads with an M-series chip.", tint: .orange)
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        // A bar, not an inset: the system scroll-edge effect keeps the buttons legible over the points.
        .safeAreaBar(edge: .bottom) {
            GlassEffectContainer {
                VStack(spacing: 12) {
                    Button(action: createSample) {
                        Text("Create Sample Project").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    Text("Downloads about \(sampleDownload.formattedBytes).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button { finish(true) } label: {
                        Text("Create Your Own Project").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    Button("Later") { finish(false) }
                }
            }
            .controlSize(.large)
            .frame(maxWidth: 560)
            .padding()
        }
        .errorAlert("Couldn't Create Project", message: $errorMessage)
    }

    private func point(_ systemImage: String, _ title: LocalizedStringKey, _ text: LocalizedStringKey,
                       tint: Color? = nil) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.tint))
                .frame(width: iconWidth)
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
                toolchains: sampleToolchains, binding: .appInternal()
            )
            provisioner.start(project)
            createdSample(project)
            finish(false)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
