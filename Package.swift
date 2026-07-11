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
        // Phase 1 kernel de-risk: a headless Metal renderer that runs the
        // Stage-B shader chain on baked layers. The interactive app reuses this
        // engine; here it renders one frame to PNG so the chain is provable
        // without any UI (`swift run nebula-render <dir> <preset> <out.png>`).
        .executable(name: "nebula-render", targets: ["NebulaRender"])
    ],
    targets: [
        .target(
            name: "NebulaCore"
        ),
        .executableTarget(
            name: "NebulaRender",
            dependencies: ["NebulaCore"]
        ),
        .testTarget(
            name: "NebulaCoreTests",
            dependencies: ["NebulaCore"],
            resources: [.copy("Fixtures")]
        )
    ]
)
