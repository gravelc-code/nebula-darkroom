// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Nebula",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        // Pure, testable core: the look model, slider↔engine mapping,
        // profiles, and the bake manifest. No Metal, no Siril, no UI.
        .library(name: "NebulaCore", targets: ["NebulaCore"]),
        // The native Metal Stage-B engine: the shader chain, FITS layer I/O, and
        // the renderer shared by the headless CLI and the interactive app.
        .library(name: "NebulaEngine", targets: ["NebulaEngine"]),
        // Headless export: renders one frame to PNG, proving the chain without
        // any UI (`swift run nebula-render <dir> <preset> <out.png>`).
        .executable(name: "nebula-render", targets: ["NebulaRender"]),
        // The interactive app: MTKView display-link loop + SwiftUI sliders.
        .executable(name: "NebulaApp", targets: ["NebulaApp"])
    ],
    targets: [
        .target(
            name: "NebulaCore"
        ),
        .target(
            name: "NebulaEngine",
            dependencies: ["NebulaCore"]
        ),
        .executableTarget(
            name: "NebulaRender",
            dependencies: ["NebulaCore", "NebulaEngine"]
        ),
        .executableTarget(
            name: "NebulaApp",
            dependencies: ["NebulaCore", "NebulaEngine"]
        ),
        .testTarget(
            name: "NebulaCoreTests",
            dependencies: ["NebulaCore"],
            resources: [.copy("Fixtures")]
        )
    ]
)
