// ConePrepass.swift — the multi-level cone-prepass plan shared by every shell.
//
// The cone prepass (perf block 9) cone-marches coarse tiles to a safe start
// depth the fine march resumes from. Block 18 generalizes it: ONE compiled
// prepass kernel, dispatched once per LEVEL of a coarse→fine hierarchy
// (e.g. 32→16→8), each level seeded from the coarser one. tileSize, coarse
// step budget, and DE iteration LOD are runtime (ThreshConePrepassParams,
// buffer 8), so the Advanced Prepass UI tunes them with no recompile.
//
// The FINEST level is always 8×8 (THRESH_CONE_TILE) — the fine march reads it
// unchanged. Coarser levels are 16, 32, … The single-level default
// (levelCount 1, stepBudget 48, iterScale 1) reproduces block-9 byte-for-byte.

import Metal
import ThresholdShaderABI

/// CPU mirror of `ThreshConePrepassParams` in RaymarchCore.metal (buffer 8).
/// Field order + sizes must match: `uint2 + uint + uint + float + uint`.
struct ConePrepassParams {
    var fullDims: SIMD2<UInt32>
    var tileSize: UInt32
    var stepBudget: UInt32
    var iterScale: Float
    var hasInput: UInt32
}

/// One level of the prepass hierarchy, coarse → fine.
struct ConePrepassLevel {
    let tileSize: Int       // pixel edge of this level's tile (finest = 8)
    let params: ConePrepassParams
}

enum ConePrepassPlan {
    /// The finest tile edge — the granularity the fine march reads
    /// (`THRESH_CONE_TILE`). Coarser levels double it per step up.
    static let finestTile = 8

    /// Levels for `levelCount` passes at `fullWidth × fullHeight`, ordered
    /// COARSE → FINE. `levelCount` is clamped to ≥ 1; the last entry is always
    /// the 8×8 level. `hasInput` is set on every level after the first, so it
    /// seeds from the coarser texture at texture 5.
    ///
    /// Tile sizes: for L levels the finest is 8 and each coarser level doubles
    /// (L=1 → [8]; L=2 → [16, 8]; L=3 → [32, 16, 8]). Doubling keeps the
    /// coarse→fine texel map an exact `gid >> 1` in the shader.
    static func levels(
        levelCount: Int, fullWidth: Int, fullHeight: Int,
        stepBudget: Int, iterScale: Float
    ) -> [ConePrepassLevel] {
        let count = max(1, levelCount)
        let budget = UInt32(max(1, stepBudget))
        let scale = min(max(iterScale, 0.05), 1.0)
        let dims = SIMD2<UInt32>(UInt32(fullWidth), UInt32(fullHeight))
        return (0..<count).map { i in
            // i = 0 is the coarsest (tile = 8·2^(count-1)); last is 8.
            let tile = finestTile << (count - 1 - i)
            let isFinest = i == count - 1
            // Iteration LOD applies to COARSE pre-passes only. The finest
            // level produces the seed the fine march resumes from, so it must
            // stay full-iteration: measured (block 18), a reduced-iteration
            // FINEST seed OVERESTIMATES distance for box-fold DEs (mandelbox)
            // and tunnels past the surface (~60% of pixels wrong). Coarse
            // levels only clear empty space, where escape-time points bail
            // early and the iteration count is immaterial — safe to cheapen.
            return ConePrepassLevel(
                tileSize: tile,
                params: ConePrepassParams(
                    fullDims: dims, tileSize: UInt32(tile),
                    stepBudget: budget,
                    iterScale: isFinest ? 1.0 : scale,
                    hasInput: i == 0 ? 0 : 1))
        }
    }

    /// Cone-texture dimensions (tiles across × down) for a level's tile size.
    static func textureSize(
        tileSize: Int, fullWidth: Int, fullHeight: Int
    ) -> (width: Int, height: Int) {
        ((fullWidth + tileSize - 1) / tileSize,
         (fullHeight + tileSize - 1) / tileSize)
    }
}
