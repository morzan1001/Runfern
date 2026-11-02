import Foundation
import Testing
@testable import Runfern

struct AppVersionTests {
    @Test func releaseTagIsDisplayed() {
        #expect(AppVersion.display(info: ["CFBundleShortVersionString": "0.0.1"]) == "v0.0.1")
        #expect(AppVersion.display(info: ["CFBundleShortVersionString": "1.2.3"]) == "v1.2.3")
    }

    @Test func missingVersionIsExplicit() {
        #expect(AppVersion.display(info: [:]) == String(localized: "Version unavailable"))
        #expect(AppVersion.display(info: ["CFBundleShortVersionString": ""]) == String(localized: "Version unavailable"))
    }
}
