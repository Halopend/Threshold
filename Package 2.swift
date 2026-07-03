// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ThresholdKit",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
        .visionOS("26.0"),
    ],
    products: [
        .library(name: "ThresholdCore", targets: ["ThresholdCore"]),
        .library(name: "ThresholdShaderIR", targets: ["ThresholdShaderIR"]),
        .library(name: "ThresholdRender", targets: ["ThresholdRender"]),
        .library(name: "ThresholdUI", targets: ["ThresholdUI"]),
        .library(name: "ThresholdInputs", targets: ["ThresholdInputs"]),
        .executable(name: "threshold-render", targets: ["threshold-render"]),
        .executable(name: "threshold-app", targets: ["threshold-app"]),
    ],
    targets: [
        // C header target: the single source of truth for structs shared Swift ↔ MSL.
        .target(
            name: "ThresholdShaderABI"
        ),
        // Catalog, modulation lanes, signals, clock, persistence. Foundation + simd only.
        .target(
            name: "ThresholdCore"
        ),
        // WarpOps, simplifier, CPU reference applyOps, DE registry.
        .target(
            name: "ThresholdShaderIR",
            dependencies: ["ThresholdShaderABI", "ThresholdCore"]
        ),
        // Metal: runtime-compiled compute pipeline, offscreen renderer.
        // MSL sources ship as plain-text resources and compile at runtime,
        // matching the external-DE path.
        .target(
            name: "ThresholdRender",
            dependencies: ["ThresholdShaderABI", "ThresholdShaderIR", "ThresholdCore"],
            resources: [.copy("MSL")]
        ),
        // SwiftUI derived from the catalog; client of the render session.
        .target(
            name: "ThresholdUI",
            dependencies: ["ThresholdCore", "ThresholdShaderIR", "ThresholdRender"]
        ),
        // Input sources: audio analysis (AVAudioEngine + vDSP) publishing
        // into the SignalTable. Hand tracking/gestures land here later.
        .target(
            name: "ThresholdInputs",
            dependencies: ["ThresholdCore"]
        ),
        // Headless CLI renderer + perf/regression harness (macOS).
        .executableTarget(
            name: "threshold-render",
            dependencies: ["ThresholdCore", "ThresholdShaderIR", "ThresholdRender"]
        ),
        // Interactive Mac dev shell: live render view + catalog-derived panels.
        .executableTarget(
            name: "threshold-app",
            dependencies: [
                "ThresholdCore", "ThresholdShaderIR", "ThresholdRender",
                "ThresholdUI", "ThresholdInputs",
            ]
        ),
        .testTarget(
            name: "ThresholdCoreTests",
            dependencies: ["ThresholdCore"]
        ),
        .testTarget(
            name: "ThresholdShaderIRTests",
            dependencies: ["ThresholdShaderIR", "ThresholdCore"]
        ),
        .testTarget(
            name: "ThresholdRenderTests",
            dependencies: ["ThresholdRender", "ThresholdShaderIR", "ThresholdCore"]
        ),
        .testTarget(
            name: "ThresholdUITests",
            dependencies: ["ThresholdUI", "ThresholdCore", "ThresholdRender"]
        ),
        .testTarget(
            name: "ThresholdInputsTests",
            dependencies: ["ThresholdInputs", "ThresholdCore"]
        ),
    ]
)
