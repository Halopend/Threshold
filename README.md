# Threshold

A live fractal raymarcher for macOS and visionOS: distance-estimated fractals
rendered by a single Metal compute core, driven by a lane-composed parameter
engine (scene / user / animation / gesture / music), with scenes saved as
`.threshscene` envelopes.

## Build & test

Requires Xcode / Swift 6 on macOS. **Always build with the native build
system** — the default swiftbuild backend fails codesigning on provenance
xattrs:

```sh
swift build --build-system native
swift test  --build-system native
```

Notes:
- The bare `.build/` executable will not present a window; run the app via
  the Xcode project (`Threshold.xcodeproj`), which wraps it in a `.app`
  bundle with its own bundle id.
- SwiftPM copied-resource directories must not be named `Resources`
  (breaks iOS/visionOS codesign) — the shader sources live in `MSL/`.

## Offscreen render / benchmark CLI

```sh
swift build --build-system native -c release
.build/release/threshold-render Corpus/legacy/scenes/Stress_test.threshscene \
  -w 1920 -h 1080 --frames 30 --specialize --stats stats.json
```

`--help` lists the flags. A/B env knobs: `THRESHOLD_SPEC_*` (function-constant
bakes), `THRESHOLD_STEP_MULTIPLIER` (over-relaxation ω),
`THRESHOLD_MATH_MODE` (fast-math seam; goldens are only valid under `safe`).

## Where things live

| Path | What |
|---|---|
| `Sources/ThresholdCore` | Parameter catalog, modulation engine, scene codec, legacy migration |
| `Sources/ThresholdShaderIR` | Warp-op IR, simplifier, CPU reference ops/DEs (the test oracle) |
| `Sources/ThresholdRender` | GPU context, sessions (interactive / visionOS compositor), specialization, `MSL/` shaders |
| `Sources/ThresholdUI` | SwiftUI control panels + `ParameterMirror` (UI ↔ render-thread seam) |
| `Sources/threshold-render` | Offscreen CLI (goldens, benchmarks) |
| `Corpus/` | Legacy scene corpus + golden images |
| `docs/` | `perf-notes.md` (baselines & measurements), `perf-port-audit.md` (ranked perf ports), `op-semantics.md`, ADRs |

Architecture and invariants: [ARCHITECTURE.md](ARCHITECTURE.md). Roadmap and
policies (incl. the legacy quarantine / phase-out policy §7.3):
[PLAN.md](PLAN.md).
