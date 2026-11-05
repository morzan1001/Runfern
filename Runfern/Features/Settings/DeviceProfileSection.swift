import SwiftUI

/// Shows what this iPad offers for Linux environments.
struct DeviceProfileSection: View {
    let profile: DeviceProfile

    var body: some View {
        Section {
            LabeledContent("Memory", value: profile.memoryDescription)
            LabeledContent("Processor Cores", value: profile.processorCount.formatted())
            LabeledContent("Resource Profiles", value: profile.supportedProfiles.map(\.title).formatted(.list(type: .and)))
            if profile.meetsTarget {
                StatusLabel("Supported iPad", systemImage: "checkmark.seal.fill", tint: .green)
            } else {
                StatusLabel("Below the supported device class (iPad with M-series chip)")
            }
        } header: {
            Text("This iPad")
        }
    }
}
