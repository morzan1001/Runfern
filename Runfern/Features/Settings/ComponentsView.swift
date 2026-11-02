import SwiftUI

/// Component inventory (Plan 6.3). The final license review happens before release.
struct ComponentsView: View {
    private let components: [(name: String, license: String, role: String)] = {
        let common: [(name: String, license: String, role: String)] = [
            ("OpenVSCode Server", "MIT", String(localized: "VS Code inside Linux")),
            ("QEMU", "GPL-2.0 / LGPL", String(localized: "Linux virtual machine")),
            ("Debian", String(localized: "Various free licenses"), String(localized: "Linux base")),
            ("Python, Node.js, Temurin, Gradle", String(localized: "Various free licenses"), String(localized: "Tools")),
        ]
        #if RUNFERN_JIT
        return common + [
            ("StikJIT", "MPL-2.0", String(localized: "Debugger for JIT")),
            ("idevice", "MIT", String(localized: "Pairing with this iPad for JIT")),
        ]
        #else
        return common
        #endif
    }()

    var body: some View {
        List(components, id: \.name) { component in
            VStack(alignment: .leading) {
                Text(component.name).font(.headline)
                Text(component.role).font(.subheadline)
                Text(component.license).font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
        .navigationTitle("Components and Licenses")
    }
}
