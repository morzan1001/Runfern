import Foundation
import Synchronization

/// Read access to the active signed catalog (see `CatalogStore`).
/// Only combinations that are explicitly listed in the catalog are offered.
nonisolated enum Catalog {
    /// Images without `source` are not published yet; URL and checksum are added after G1.
    static var baseImages: [BaseImage] { activeCatalog.withLock { $0.baseImages } }

    static var toolchains: [ToolchainProfile] { activeCatalog.withLock { $0.toolchains } }

    static func baseImage(id: String) -> BaseImage? {
        baseImages.first { $0.id == id }
    }

    static func toolchain(id: String) -> ToolchainProfile? {
        toolchains.first { $0.id == id }
    }

    static func toolchains(for image: BaseImage) -> [ToolchainProfile] {
        toolchains.filter { image.supportedToolchains.contains($0.id) }
    }

    static func recipe(for environment: DevEnvironment) -> EnvironmentRecipe? {
        guard let image = baseImage(id: environment.baseImageId) else { return nil }
        return EnvironmentRecipe(
            base: .init(id: image.id, distribution: image.distribution, release: image.release,
                        architecture: image.architecture, catalogVersion: environment.baseCatalogVersion,
                        sha256: image.source?.sha256),
            toolchains: environment.toolchainIds.compactMap { id in
                toolchain(id: id).map { .init(id: $0.id, revision: $0.revision) }
            }
        )
    }

    /// Recipe components the catalog no longer offers (IMG02/NEW07).
    static func missingComponents(of environment: DevEnvironment) -> [String] {
        var missing: [String] = []
        if let image = baseImage(id: environment.baseImageId) {
            if image.catalogVersion != environment.baseCatalogVersion {
                missing.append(String(localized: "\(image.displayName) in catalog version \(environment.baseCatalogVersion)"))
            }
        } else {
            missing.append(String(localized: "Linux base \(environment.baseImageId)"))
        }
        missing += environment.toolchainIds
            .filter { toolchain(id: $0) == nil }
            .map { String(localized: "Toolchain profile \($0)") }
        return missing
    }

    /// Files of the starter templates. Existing files are never overwritten (NEW02).
    static func templateFiles(for source: ProjectSource) -> [String: String] {
        switch source {
        case .empty, .existingFolder:
            return [:]
        case .pythonStarter:
            return [
                "main.py": """
                def greet(name: str) -> str:
                    return f"Hello, {name}!"


                if __name__ == "__main__":
                    print(greet("iPad"))

                """,
                "test_main.py": """
                from main import greet


                def test_greet():
                    assert greet("World") == "Hello, World!"

                """,
                "README.md": """
                # Python Starter Project

                Run in the terminal: `python3 main.py`
                Tests: `python3 -m pytest`

                """,
                ".gitignore": "__pycache__/\n.venv/\n",
            ]
        }
    }
}
