// swift-tools-version:6.0
// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
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
        .executable(name: "NebulaApp", targets: ["NebulaApp"]),
        // Phase 2: native in-process AI (GraXpert models via onnxruntime),
        // replacing the GraXpert subprocess. Probe proves ORT links from Swift;
        // nebula-ai is the FITS-in/FITS-out tool the bake wrappers call.
        .executable(name: "nebula-ai-probe", targets: ["NebulaAIProbe"]),
        .executable(name: "nebula-ai", targets: ["NebulaAICLI"]),
        // Phase 3: the native Swift bake orchestrator (Siril subprocess + AI
        // in-process + typed manifest), replacing the Python bake seam.
        .executable(name: "nebula-bake-native", targets: ["NebulaBakeCLI"])
    ],
    dependencies: [
        // onnxruntime C/Obj-C runtime as a binary xcframework. Pinned to 1.19.2
        // to match the Python spike that proved model parity (prototype/ai_native).
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager",
                 exact: "1.19.2")
    ],
    targets: [
        .target(
            name: "NebulaCore"
        ),
        .target(
            name: "NebulaEngine",
            dependencies: ["NebulaCore"]
        ),
        .target(
            name: "NebulaAI",
            dependencies: [
                "NebulaEngine",
                .product(name: "onnxruntime",
                         package: "onnxruntime-swift-package-manager")
            ]
        ),
        .executableTarget(
            name: "NebulaAIProbe",
            dependencies: ["NebulaAI"]
        ),
        .executableTarget(
            name: "NebulaAICLI",
            dependencies: ["NebulaAI", "NebulaEngine"]
        ),
        .target(
            name: "NebulaBake",
            dependencies: ["NebulaCore", "NebulaEngine", "NebulaAI"]
        ),
        .executableTarget(
            name: "NebulaBakeCLI",
            dependencies: ["NebulaBake", "NebulaCore"]
        ),
        .executableTarget(
            name: "NebulaRender",
            dependencies: ["NebulaCore", "NebulaEngine", "NebulaAI"]
        ),
        .executableTarget(
            name: "NebulaApp",
            dependencies: ["NebulaCore", "NebulaEngine", "NebulaBake", "NebulaAI"]
        ),
        .testTarget(
            name: "NebulaCoreTests",
            dependencies: ["NebulaCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "NebulaEngineTests",
            dependencies: ["NebulaEngine"]
        ),
        .testTarget(
            name: "NebulaBakeTests",
            dependencies: ["NebulaBake", "NebulaEngine"]
        ),
        .testTarget(
            name: "NebulaAITests",
            dependencies: ["NebulaAI"]
        )
    ]
)
