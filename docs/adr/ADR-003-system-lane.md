# ADR-003: Explicit `system` modulation lane

**Status:** Accepted
**Date:** 2026-07-02
**Deciders:** Jean
**Relates to:** ARCHITECTURE.md §6, plan §3.1/§6.4

## Context

The plan fixes lane order globally: `scene ▷ animation ▷ user ▷ gesture ▷ music`.
It then (§6.4) routes the visionOS quality governor through "animation lane
semantics… a system writer with its own lane priority below user." That is a second,
implicit lane hiding inside an existing one — the exact pattern (two writers sharing
a slot) the lane model exists to forbid. Other automated writers with the same need
are coming: safety clamps (flashing-risk limiter), platform caps (Mixed-immersion
size cap).

## Decision

Add a sixth lane. Global order: `scene ▷ animation ▷ system ▷ user ▷ gesture ▷ music`.
Only automated non-user writers (governor, safety limiter, platform caps) may write
`system`; each such writer is registered and named. Invariant 16 encodes this.

## Options Considered

### Option A: Explicit system lane (chosen)
**Pros:** governor/caps get a principled home; user lane stays purely "what the human
did"; debugging shows exactly which layer moved a value. Cost is one more dense float
array and one more mailbox — O(paramCount) memory, trivial.
**Cons:** one more concept; lane order below `user` means the user can override the
governor (see trade-offs).

### Option B: Governor writes through animation-lane semantics (plan §6.4)
**Cons:** two writers, one lane — animation playback and the governor collide on any
param both touch; "stopping playback zeroes the lane" would zero governor output.
Rejected as self-inconsistent with plan Invariant 2.

### Option C: Governor bypasses lanes, clamps at resolution
**Cons:** invisible to snapshot introspection and to the UI's "why is this value
lower than my slider" story; a special case forever.

## Trade-off Analysis

Placement *below* user is deliberate but subtle: for `renderQuality` the user slider
is a **ceiling**, so the governor's system-lane write must compose multiplicatively
(0…1 factor) rather than additively — the resolved value is `user × system` and the
user can lower but not raise past the governor. This means composition mode matters
per (param, lane), which the catalog's `Composition` already expresses; document that
quality-class params declare `.multiplicative`. Safety clamps that must win over the
user (flashing limiter) are instead applied as *range narrowing* at the final clamp —
a declared apply-policy rule, not a lane, because "user must not be able to override"
contradicts any below-music lane position.

## Consequences

- Easier: attributing any resolved value to its writers; adding future automated
  writers.
- Harder: one more lane to reason about in grab-what-you-see inversion (the inverse
  solves for the user lane treating system as a known term — already handled).
- Revisit if a writer appears that fits neither `system` (user-overridable) nor
  final-clamp narrowing (user-proof).

## Action Items

1. [ ] Encode "registered system writers" as a small enum; reject unregistered writes.
2. [ ] Property-test grab-what-you-see inversion with nonzero system lane.
3. [ ] Specify the flashing-risk limiter as final-clamp narrowing, not a lane write.

## Update — 2026-07-03 (perf block 5)

The quality governor no longer writes the system lane at all. Its
iterations/maxSteps writes were removed after live testing showed them
visibly reshaping the DE (the mandelbulb's detail threshold jumped
discontinuously under load); the governor now emits only a resolution scale
(`SessionFrame.request.renderScale`), applied through each platform's native
mechanism — visionOS compositor `renderQuality`, Mac/iOS MetalFX temporal
upscaling (docs/perf-notes.md perf block 5). Resolution softens; it never
reshapes the fractal, and it lives outside the param/lane system entirely
(it is not a param a user could bind or animate).

The lane itself stands: it remains the home for future automated
param-writers (safety clamps, platform caps), and the `.multiplicative`
quality-class composition documented above is unchanged for them.
