// Inversion.swift — grab-what-you-see (ARCHITECTURE.md §3 "Grab-what-you-see,
// precisely"; plan §3.2 user-lane semantics).
//
// On slider grab, the UI shows the RESOLVED value; the drag must write the
// user lane such that the resolved value matches the thumb. That makes the
// user-lane write the inverse of the composition chain — "the one piece of
// math the whole UI feel depends on." It is a pure function of the engine's
// current lane state, property-tested (`resolve(invert(x)) == clamp(x)` for
// arbitrary lane states, including a nonzero system lane — ADR-003 action
// item 2).

/// Pure inversion of the lane composition chain.
public enum Inversion {
    /// Compute the user-lane value that makes the resolved value equal
    /// `clamp(target)` given the current contributions of every OTHER lane
    /// (scene-or-default base, animation, system, gesture, music — their
    /// current *smoothed* values).
    ///
    /// Per composition:
    /// - `.additive`: `user = clamp(target) − Σ(other set lanes) − base`.
    /// - `.multiplicative`: `user = clamp(target) / Π(other set lanes × base)`;
    ///   if that product is within ~0 (`|Π| < 1e-6`) the chain is not
    ///   invertible — returns the multiplicative NEUTRAL (1).
    /// - `.replace`: the user lane simply IS the value — returns
    ///   `clamp(target)` itself. Note that a set gesture/music lane composes
    ///   AFTER user and would replace it; the guarantee
    ///   `resolve() == clamp(target)` holds when no higher transient lane
    ///   holds an explicit value on this slot.
    ///
    /// The guarantee also assumes the user lane applies instantly (its
    /// default smoothing is tau 0) and that the slot is not an integrator
    /// phase (integrators override composition). Unregistered slots return
    /// `target` unchanged.
    ///
    /// Pure: reads engine state, mutates nothing.
    public static func userLaneValue(
        toAchieve target: Float,
        slot: Int,
        in engine: ModulationEngine
    ) -> Float {
        precondition(slot >= 0 && slot < engine.layout.slotCount, "slot \(slot) out of bounds")
        guard let composition = engine.compositionForSlot(slot) else { return target }
        let clamped = engine.clampToRange(target, slot: slot)

        // Every lane except .user, in composition order. Additive and
        // multiplicative are commutative so order is irrelevant there;
        // replace is handled without needing the others.
        let otherLanes: [Lane] = [.animation, .system, .gesture, .music]

        switch composition {
        case .replace:
            return clamped

        case .additive:
            var sum = engine.baseValue(slot: slot)
            for lane in otherLanes {
                if let v = engine.currentValue(lane: lane, slot: slot) { sum += v }
            }
            return clamped - sum

        case .multiplicative:
            var product = engine.baseValue(slot: slot)
            for lane in otherLanes {
                if let v = engine.currentValue(lane: lane, slot: slot) { product *= v }
            }
            guard abs(product) > 1e-6 else { return 1 }  // not invertible → neutral
            return clamped / product
        }
    }

    /// Compute the SCENE-lane (authored base) value that makes the resolved
    /// value equal `clamp(target)` once the momentary USER lane is cleared —
    /// i.e. the value to COMMIT a slider edit into so it persists and saves.
    /// Same inversion as `userLaneValue`, but the scene lane IS the base (no
    /// separate base term) and the user lane is excluded (it is cleared on
    /// commit). The other transient lanes (animation/system/gesture/music) keep
    /// their current contribution, so grab-what-you-see continuity holds.
    ///
    /// Pure: reads engine state, mutates nothing.
    public static func sceneLaneValue(
        toAchieve target: Float,
        slot: Int,
        in engine: ModulationEngine
    ) -> Float {
        precondition(slot >= 0 && slot < engine.layout.slotCount, "slot \(slot) out of bounds")
        guard let composition = engine.compositionForSlot(slot) else { return target }
        let clamped = engine.clampToRange(target, slot: slot)
        let otherLanes: [Lane] = [.animation, .system, .gesture, .music]

        switch composition {
        case .replace:
            return clamped

        case .additive:
            var sum: Float = 0
            for lane in otherLanes {
                if let v = engine.currentValue(lane: lane, slot: slot) { sum += v }
            }
            return clamped - sum

        case .multiplicative:
            var product: Float = 1
            for lane in otherLanes {
                if let v = engine.currentValue(lane: lane, slot: slot) { product *= v }
            }
            guard abs(product) > 1e-6 else { return clamped }  // not invertible → target
            return clamped / product
        }
    }
}
