import Foundation
import Testing
@testable import Runfern

/// Verifies the device class check (Plan 2.1, D01).
@Suite struct DeviceProfileTests {
    private func profile(memoryGB: UInt64, cores: Int) -> DeviceProfile {
        DeviceProfile(modelIdentifier: "iPad", physicalMemory: memoryGB * 1024 * 1024 * 1024,
                      processorCount: cores, systemVersion: "27")
    }

    @Test func mSeriesClassMeetsTarget() {
        let device = profile(memoryGB: 8, cores: 8)

        #expect(device.meetsTarget)
        #expect(device.supportedProfiles == [.light, .standard])
    }

    @Test func olderDevicesAreFlagged() {
        let device = profile(memoryGB: 4, cores: 6)

        #expect(!device.meetsTarget)
        #expect(device.supportedProfiles == [.light])
    }

    @Test func currentDeviceReportsAModel() {
        #expect(!DeviceProfile.current.modelIdentifier.isEmpty)
        #expect(DeviceProfile.current.processorCount > 0)
    }
}
