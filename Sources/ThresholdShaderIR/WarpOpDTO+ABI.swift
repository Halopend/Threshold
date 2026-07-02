// WarpOpDTO+ABI.swift — bridge between the persistence DTO (ThresholdCore,
// deliberately ABI-free) and the GPU struct. This is the ONLY place scene
// warp stacks become device data (plan §7.1 → §5.2).

import ThresholdCore
import ThresholdShaderABI

extension ThreshWarpOp {
    /// Build a GPU op from a scene DTO. Returns nil for unknown kinds — the
    /// loader warns and preserves them in the envelope rather than crashing
    /// or silently rendering garbage (plan §7.1: never trust-and-crash).
    public init?(dto: WarpOpDTO) {
        guard WarpKind(rawValue: dto.kind) != nil else { return nil }
        self.init()
        kind = dto.kind
        flags = dto.flags
        strength = dto.strength
        a = SIMD4(dto.a[0], dto.a[1], dto.a[2], dto.a[3])
        b = SIMD4(dto.b[0], dto.b[1], dto.b[2], dto.b[3])
    }
}

extension WarpOpDTO {
    /// Snapshot a GPU op back into persistence form.
    public init(op: ThreshWarpOp) {
        self.init(
            kind: op.kind,
            flags: op.flags,
            strength: op.strength,
            a: [op.a.x, op.a.y, op.a.z, op.a.w],
            b: [op.b.x, op.b.y, op.b.z, op.b.w]
        )
    }
}

extension Array where Element == ThreshWarpOp {
    /// Convert a scene warp stack, splitting off unknown kinds for warning.
    public static func fromDTOs(_ dtos: [WarpOpDTO]) -> (ops: [ThreshWarpOp], unknownKinds: [UInt32]) {
        var ops: [ThreshWarpOp] = []
        var unknown: [UInt32] = []
        for dto in dtos {
            if let op = ThreshWarpOp(dto: dto) {
                ops.append(op)
            } else {
                unknown.append(dto.kind)
            }
        }
        return (ops, unknown)
    }
}
