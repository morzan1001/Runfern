import SwiftUI

/// Component inventory (Plan 6.3). The final license review happens before release.
struct ComponentsView: View {
    private let components: [(name: String, license: String, role: String)] = [
        ("OpenVSCode Server", "MIT", String(localized: "VS Code inside Linux")),
        ("QEMU", "GPL-2.0 / LGPL", String(localized: "Linux virtual machine")),
        ("Debian", String(localized: "Various free licenses"), String(localized: "Linux base")),
        ("Python, Node.js, Temurin, Gradle", String(localized: "Various free licenses"), String(localized: "Tools")),
    ]

    var body: some View {
        List(components, id: \.name) { component in
            VStack(alignment: .leading) {
                Text(component.name).font(.headline)
                Text(component.role).font(.subheadline)
                Text(component.license).font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Components and Licenses")
    }
}
