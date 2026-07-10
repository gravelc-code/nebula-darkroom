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
        .library(name: "NebulaCore", targets: ["NebulaCore"])
    ],
    targets: [
        .target(
            name: "NebulaCore"
        ),
        .testTarget(
            name: "NebulaCoreTests",
            dependencies: ["NebulaCore"],
            resources: [.copy("Fixtures")]
        )
    ]
)
