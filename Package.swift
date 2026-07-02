// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ThresholdKit",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
        .visionOS(.v2),
    ],
    products: [
        .library(name: "ThresholdCore", targets: ["ThresholdCore"]),
        .library(name: "ThresholdShaderIR", targets: ["ThresholdShaderIR"]),
        .library(name: "ThresholdRender", targets: ["ThresholdRender"]),
        .executable(name: "threshold-render", targets: ["threshold-render"]),
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
            resources: [.copy("Resources")]
        ),
        // Headless CLI renderer + perf/regression harness (macOS).
        .executableTarget(
            name: "threshold-render",
            dependencies: ["ThresholdCore", "ThresholdShaderIR", "ThresholdRender"]
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
    ]
)
