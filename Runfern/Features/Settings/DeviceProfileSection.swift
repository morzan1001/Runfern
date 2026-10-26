import SwiftUI

/// Shows what this iPad offers for Linux environments (Plan 2.1, RUN07).
struct DeviceProfileSection: View {
    let profile: DeviceProfile

    var body: some View {
        Section {
            LabeledContent("Memory", value: profile.memoryDescription)
            LabeledContent("Processor Cores", value: profile.processorCount.formatted())
            LabeledContent("Resource Profiles", value: profile.supportedProfiles.map(\.title).formatted(.list(type: .and)))
            if profile.meetsTarget {
                Label("Supported iPad", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else {
                Label("Below the supported device class (iPad with M-series chip)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("This iPad")
        }
    }
}
