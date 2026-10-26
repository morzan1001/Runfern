import Foundation

/// State of an environment (Plan 4.6). The transient VM session is modeled separately.
nonisolated enum RuntimeState: String, Codable, Sendable {
    case provisioning   // setup is running or was interrupted
    case ready          // ready to start
    case starting
    case running
    case stopping
    case stopped
    case repairNeeded   // ended uncleanly or setup was interrupted
    case failed

    var title: String {
        switch self {
        case .provisioning: String(localized: "Setting Up")
        case .ready: String(localized: "Ready")
        case .starting: String(localized: "Starting")
        case .running: String(localized: "Running")
        case .stopping: String(localized: "Stopping")
        case .stopped: String(localized: "Stopped")
        case .repairNeeded: String(localized: "Interrupted")
        case .failed: String(localized: "Failed")
        }
    }

    var systemImage: String {
        switch self {
        case .provisioning: "arrow.down.circle"
        case .ready, .stopped: "pause.circle"
        case .starting, .stopping: "hourglass"
        case .running: "play.circle.fill"
        case .repairNeeded: "arrow.counterclockwise.circle"
        case .failed: "exclamationmark.triangle"
        }
    }
}

/// Setup steps in a fixed order. Every step is repeatable (NEW06).
nonisolated enum ProvisioningStep: String, Codable, CaseIterable, Sendable {
    case checkStorage
    case fetchBase
    case createSystemDisk
    case prepareWorkspace
    case installToolchains
    case verify

    var title: String {
        switch self {
        case .checkStorage: String(localized: "Check available storage")
        case .fetchBase: String(localized: "Download and verify Linux base")
        case .createSystemDisk: String(localized: "Create system disk")
        case .prepareWorkspace: String(localized: "Prepare workspace")
        case .installToolchains: String(localized: "Install tools")
        case .verify: String(localized: "Run health check")
        }
    }
}

/// Persistent Linux installation including its tools. Contains no source code.
nonisolated struct DevEnvironment: Identifiable, Codable, Sendable {
    let id: UUID
    let baseImageId: String
    let baseCatalogVersion: Int
    /// Installed toolchain profiles; more can be added later (IMG07).
    var toolchainIds: [String]
    var state: RuntimeState
    /// Setup steps already completed (raw values of `ProvisioningStep`).
    var completedSteps: [String]
    var lastError: String?
    /// `nil` for environments created before resource profiles existed; they use the default.
    var resources: ResourceProfile?
    /// VS Code extensions chosen in addition to those of the tools (Open VSX identifiers).
    var extensionIds: [String]? = nil
    /// VS Code user settings (JSON object) applied during setup, usually from a preset.
    var editorSettings: String? = nil
    /// Build of the Linux base the system disk was created on (see `ImageBundle.Manifest.buildID`).
    var baseBuildID: String? = nil
    /// Extensions that tools bring along but the person deselected.
    var excludedExtensionIds: [String]? = nil
    /// What the guest actually has; setup removes whatever is no longer selected.
    var installedToolchainIds: [String]? = nil
    var installedExtensionIds: [String]? = nil
    /// VS Code is adapted for touch by the app (see `EditorTouchScript`); `nil` means off.
    var touchOptimized: Bool? = nil

    func hasCompleted(_ step: ProvisioningStep) -> Bool { completedSteps.contains(step.rawValue) }
    var isFullyProvisioned: Bool { ProvisioningStep.allCases.allSatisfy(hasCompleted) }
    var effectiveResources: ResourceProfile { resources ?? .standard }
    var customExtensions: [String] { extensionIds ?? [] }

    var software: SoftwareSelection {
        SoftwareSelection(toolchainIds: toolchainIds, customExtensions: customExtensions,
                          excludedExtensions: excludedExtensionIds ?? [], touchOptimized: touchOptimized ?? false)
    }
}

/// The tools and VS Code extensions chosen for an environment. Tools suggest their extensions;
/// the person can deselect those and add others from Open VSX.
nonisolated struct SoftwareSelection: Codable, Hashable, Sendable {
    var toolchainIds: [String]
    var customExtensions: [String] = []
    var excludedExtensions: [String] = []
    /// Touch-friendly VS Code. Applied by the app, so changing it needs no setup in Linux.
    var touchOptimized = false

    var toolchains: [ToolchainProfile] { toolchainIds.compactMap(Catalog.toolchain(id:)) }

    /// Extensions suggested by the selected tools, in tool order and without duplicates.
    var suggestedExtensions: [String] {
        var seen = Set<String>()
        return toolchains.flatMap(\.extensions).filter { seen.insert($0).inserted }
    }

    /// Everything that ends up in VS Code.
    var extensions: [String] {
        var seen = Set<String>()
        return (suggestedExtensions.filter { !excludedExtensions.contains($0) } + customExtensions)
            .filter { seen.insert($0).inserted }
    }

    /// Same tools and extensions, so the environment needs no new setup.
    func installsSameSoftware(as other: SoftwareSelection) -> Bool {
        Set(toolchainIds) == Set(other.toolchainIds) && extensions == other.extensions
    }

    mutating func setTool(_ id: String, selected: Bool) {
        toolchainIds.removeAll { $0 == id }
        if selected { toolchainIds.append(id) }
    }

    mutating func setExtension(_ id: String, selected: Bool) {
        if suggestedExtensions.contains(id) {
            excludedExtensions.removeAll { $0 == id }
            if !selected { excludedExtensions.append(id) }
        } else {
            customExtensions.removeAll { $0 == id }
            if selected { customExtensions.append(id) }
        }
    }
}

/// VS Code extensions from Open VSX, identified as `publisher.name`.
nonisolated enum EditorExtension {
    static func isValidID(_ id: String) -> Bool {
        id.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9-]*\.[A-Za-z0-9][A-Za-z0-9-]*/) != nil
    }
}

/// Verified resource presets for the VM (RUN07). Free-form values are intentionally not offered.
nonisolated enum ResourceProfile: String, Codable, CaseIterable, Sendable {
    case light
    case standard
    case performance

    var memoryMB: Int {
        switch self {
        case .light: 2048
        case .standard: 3072
        case .performance: 6144
        }
    }

    var cpuCount: Int {
        switch self {
        case .light: 2
        case .standard: 4
        case .performance: 6
        }
    }

    var title: String {
        switch self {
        case .light: String(localized: "Light")
        case .standard: String(localized: "Standard")
        case .performance: String(localized: "Performance")
        }
    }

    /// The VM may use at most half of the device memory so iPadOS and the app keep enough headroom (R02).
    func isSupported(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory,
                     processorCount: Int = ProcessInfo.processInfo.activeProcessorCount) -> Bool {
        UInt64(memoryMB) * 1024 * 1024 <= physicalMemory / 2 && cpuCount <= processorCount
    }
}

/// Human-readable environment recipe (NEW07). Deliberately contains no credentials.
nonisolated struct EnvironmentRecipe: Codable, Sendable {
    struct Base: Codable, Sendable {
        let id: String
        let distribution: String
        let release: String
        let architecture: String
        let catalogVersion: Int
        let sha256: String?
    }
    struct Toolchain: Codable, Sendable {
        let id: String
        let revision: Int
    }

    var format = 1
    let base: Base
    let toolchains: [Toolchain]
}
