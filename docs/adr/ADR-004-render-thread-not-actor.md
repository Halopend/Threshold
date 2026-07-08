# ADR-004: Render loop is a dedicated thread, not a Swift actor

**Status:** Accepted
**Date:** 2026-07-02
**Deciders:** Jean
**Relates to:** ARCHITECTURE.md §2, plan §3.3/§10

## Context

Swift 6 strict concurrency wants every mutable state isolated somewhere. The natural
candidates for the render loop: a Swift `actor`, `@MainActor`, or a dedicated thread
with manually-audited crossings. The loop must run drain → resolve → encode inside a
frame callback (`CAMetalDisplayLink` / Compositor frame loop) with bounded latency at
90–120 Hz, and lane resolution is a tight SIMD pass over dense arrays.

## Decision

A dedicated thread owns lane storage, integrator state, the snapshot ring, and Metal
encoding. It is reached only via two lock-free structures (Invariant 13): a seqlock
signal table (latest-value per signal) and an MPSC command mailbox (structural
changes, drained at frame start). `FrameSnapshot` is deeply immutable and `Sendable`;
it is the only object that leaves the thread.

## Options Considered

### Option A: Dedicated thread + two lock-free crossings (chosen)
**Pros:** bounded latency (no executor hops, no awaits in the frame path); matches
how CAMetalDisplayLink/Compositor callbacks actually deliver frames; the harness
drives the same code with a plain function call.
**Cons:** the crossings are `@unchecked Sendable` — correctness is ours to prove.
Specifically: (a) seqlock cells hold >64-bit payloads, so reads must use a version
counter with acquire/release ordering (swift-atomics), retry on odd/changed version —
ARM's weaker memory model makes "it worked on my machine" insufficient, this needs a
TSAN-exempt, litmus-tested implementation; (b) MPSC queue must not allocate on the
publish path (writers may be the audio thread).

### Option B: Swift actor
**Pros:** compiler-proven isolation, zero unsafe code.
**Cons:** actors provide no latency bound or priority guarantee; frame callbacks
would `await` into the actor (executor hop per frame, priority inversion risk vs. the
audio thread); custom executors help but then you're hand-rolling Option A with extra
steps. Rejected for the frame path; fine elsewhere.

### Option C: Everything on MainActor
**Cons:** SwiftUI work and render resolution contend; a slow UI frame drops a render
frame. Rejected — though note the *mirror* (UI readback) is MainActor by design.

## Trade-off Analysis

We accept two small, audited unsafe types in exchange for deterministic frame timing.
The blast radius is contained: both types live in one file each in `ThresholdCore`,
have no dependencies, and are property-tested under contention. Everything else in
the app is compiler-checked Swift 6 isolation.

## Consequences

- Easier: determinism (harness calls `step(dt:)` synchronously), frame-time budgeting,
  reasoning about who mutates lanes (nobody but the resolver).
- Harder: the two lock-free types need real concurrency review; contributors must
  learn "no third channel" (Invariant 13).
- Revisit if Swift gains real-time-safe custom executors with latency guarantees.

## Action Items

1. [ ] Implement `SignalTable` with swift-atomics; stress-test under TSAN + a
   contention harness on Apple silicon (ARM ordering).
2. [ ] Implement the MPSC command mailbox allocation-free on the publish path.
3. [ ] CI grep-gate: `@unchecked Sendable` allowed only in the two named files.
