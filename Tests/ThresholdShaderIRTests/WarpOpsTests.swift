// WarpOpsTests.swift — typed constructors, registration metadata, and the
// payload field catalog.

import Testing
import ThresholdCore
import ThresholdShaderABI
@testable import ThresholdShaderIR

@Suite("WarpOps constructors & metadata")
struct WarpOpsTests {
    @Test("Registration metadata: isometric exactly where op-semantics says so")
    func isometricSet() {
        let isometric: Set<WarpKind> = [
            .mirror, .boxFold, .planeFold, .kaleidoscope,
            .coxeter, .mengerFold, .offsetFold, .tiling,
        ]
        for kind in WarpKind.allCases {
            #expect(kind.isIsometric == isometric.contains(kind),
                    "\(kind) isometric flag wrong")
            #expect(WarpKind.isIsometric(kind) == kind.isIsometric)
        }
        // Shells is piecewise-isometric radially but NOT stamped isometric.
        #expect(!WarpKind.shells.isIsometric)
    }

    @Test("Registration metadata: distance ops are exactly kind >= 64")
    func distanceOpSet() {
        for kind in WarpKind.allCases {
            #expect(kind.isDistanceOp == (kind.rawValue >= 64))
            #expect(WarpKind.isDistanceOp(kind) == kind.isDistanceOp)
        }
        #expect(!WarpKind.none.isPointOp)
        #expect(WarpKind.twist.isPointOp)
        #expect(!WarpKind.handAttract.isPointOp)
    }

    @Test("Point-op constructors populate kind/strength/payload per ADR-002")
    func pointConstructors() {
        let twist = ThreshWarpOp.twist(axis: SIMD3(0, 0, 2), strength: 0.5)
        #expect(twist.kind == WarpKind.twist.rawValue)
        #expect(twist.strength == 0.5)
        #expect(twist.a == SIMD4<Float>(0, 0, 2, 0))
        #expect(twist.flags == 0)

        let ripple = ThreshWarpOp.ripple(axis: SIMD3(1, 0, 0), frequency: 3, strength: 0.25)
        #expect(ripple.kind == WarpKind.ripple.rawValue)
        #expect(ripple.a == SIMD4<Float>(1, 0, 0, 3))

        let box = ThreshWarpOp.boxFold(limit: 1.5, hallOfMirrors: true, strength: 1)
        #expect(box.kind == WarpKind.boxFold.rawValue)
        #expect(box.a.x == 1.5)
        #expect(box.warpFlags.contains(.optionA))
        let boxPlain = ThreshWarpOp.boxFold(limit: 1.5, strength: 1)
        #expect(!boxPlain.warpFlags.contains(.optionA))

        let plane = ThreshWarpOp.planeFold(normal: SIMD3(0, 1, 0), distance: -0.5, strength: 1)
        #expect(plane.a == SIMD4<Float>(0, 1, 0, -0.5))

        let cox = ThreshWarpOp.coxeter(p: 4, q: 3, strength: 1)
        #expect(cox.a.x == 4 && cox.a.y == 3)

        let kal = ThreshWarpOp.kaleidoscope(segments: 6, strength: 1)
        #expect(kal.a.x == 6)

        let sphereFold = ThreshWarpOp.sphereFold(minRadius: 0.25, fixedRadius: 1, strength: 1)
        #expect(sphereFold.a.x == 0.25 && sphereFold.a.y == 1)

        let tube = ThreshWarpOp.tubeFold(innerRadius: 0.3, outerRadius: 1.2, strength: 0.7)
        #expect(tube.a.x == 0.3 && tube.a.y == 1.2)

        let tiling = ThreshWarpOp.tiling(cellSize: 2, repeatX: true, repeatY: false, repeatZ: true, strength: 1)
        #expect(tiling.a.x == 2)
        #expect(tiling.b == SIMD4<Float>(1, 0, 1, 0))

        let offset = ThreshWarpOp.offsetFold(center: SIMD3(0.1, 0.2, 0.3), strength: 1)
        #expect(offset.a.xyz == SIMD3<Float>(0.1, 0.2, 0.3))

        for op in [ThreshWarpOp.mirror(), .mengerFold(strength: 1)] {
            #expect(op.a == SIMD4<Float>.zero && op.b == SIMD4<Float>.zero)
        }
        #expect(ThreshWarpOp.mirror().strength == 1) // default full strength

        #expect(ThreshWarpOp.shells(spacing: 0.8, strength: 1).a.x == 0.8)
        #expect(ThreshWarpOp.scaleRepeat(factor: 2, strength: 1).a.x == 2)
        #expect(ThreshWarpOp.scale(factor: 0.5, strength: 1).a.x == 0.5)
        #expect(ThreshWarpOp.sphereInvert(radius: 1.5, strength: 1).a.x == 1.5)
        #expect(ThreshWarpOp.sphereProject(radius: 2, strength: 0.5).a.x == 2)
    }

    @Test("Hand-op constructors pack payloads per plan §4.4")
    func handConstructors() {
        let hand = ThreshWarpOp.handAttract(
            center: SIMD3(0.1, 0.2, 0.3), radius: 0.4,
            ballScale: 0.9, softness: 0.15,
            pocketSize: 0.5, pocketSoftness: 0.05,
            pocketEnabled: true, strength: -0.75)
        #expect(hand.kind == WarpKind.handAttract.rawValue)
        #expect(hand.a == SIMD4<Float>(0.1, 0.2, 0.3, 0.4))
        #expect(hand.b == SIMD4<Float>(0.9, 0.15, 0.5, 0.05))
        #expect(hand.warpFlags.contains(.optionA))
        #expect(hand.strength == -0.75) // sign selects attract/repel

        let carve = ThreshWarpOp.forearmCarve(
            from: SIMD3(0, 0, 0), to: SIMD3(0, 1, 0),
            radius: 0.2, softness: 0.1, strength: 1)
        #expect(carve.kind == WarpKind.forearmCarve.rawValue)
        #expect(carve.a == SIMD4<Float>(0, 0, 0, 0.2))
        #expect(carve.b == SIMD4<Float>(0, 1, 0, 0.1))
        #expect(carve.flags == 0) // no sign/flag field, structurally
    }

    @Test("Bounding constructor packs shape/scale/softness + mode/placement flags")
    func boundingConstructor() {
        // Defaults: intersect + in-stack → no flags; strength 1 (survives the
        // simplifier's strength==0 drop).
        let inStack = ThreshWarpOp.bounding(shape: .octahedron, scale: 1.5)
        #expect(inStack.kind == WarpKind.bounding.rawValue)
        #expect(inStack.a == SIMD4<Float>(BoundingShape.octahedron.shapeCode, 1.5, 0.05, 0))
        #expect(inStack.flags == 0)
        #expect(inStack.strength == 1)

        // Subtract + fixed sets both option bits.
        let fixed = ThreshWarpOp.bounding(
            shape: .icosahedron, scale: 0.8, mode: .subtract,
            placement: .fixed, softness: 0.1, strength: 0.6)
        #expect(fixed.a == SIMD4<Float>(BoundingShape.icosahedron.shapeCode, 0.8, 0.1, 0))
        #expect(fixed.warpFlags.contains(.optionA)) // subtract
        #expect(fixed.warpFlags.contains(.optionB)) // fixed
        #expect(fixed.strength == 0.6)

        // Shape code round-trips through the a.x storage.
        for shape in BoundingShape.allCases {
            let op = ThreshWarpOp.bounding(shape: shape, scale: 1)
            #expect(BoundingShape(code: op.a.x) == shape)
        }
    }

    @Test("Payload field catalog covers every kind consistently")
    func payloadCatalog() {
        for kind in WarpKind.allCases {
            let fields = kind.payloadFields
            // Only None exposes nothing; every real kind (Bounding included)
            // leads with the universally bindable strength.
            if kind == .none {
                #expect(fields.isEmpty)
                continue
            }
            #expect(fields.first?.path == .strength, "\(kind) must lead with strength")
            // Field names are unique within a kind (they become catalog keys).
            #expect(Set(fields.map(\.name)).count == fields.count)
            // No two fields overlap the same payload path.
            #expect(Set(fields.map(\.path)).count == fields.count)
        }
    }

    @Test("Payload field catalog matches the constructors' packing")
    func payloadCatalogSpotChecks() {
        func paths(_ kind: WarpKind) -> [String: WarpPayloadPath] {
            Dictionary(uniqueKeysWithValues: kind.payloadFields.map { ($0.name, $0.path) })
        }
        #expect(paths(.twist)["axis"] == .a(.xyz))
        #expect(paths(.ripple)["frequency"] == .a(.w))
        #expect(paths(.boxFold)["limit"] == .a(.x))
        #expect(paths(.boxFold)["hallOfMirrors"] == .flagBit(0))
        #expect(paths(.planeFold)["normal"] == .a(.xyz))
        #expect(paths(.planeFold)["distance"] == .a(.w))
        #expect(paths(.coxeter)["p"] == .a(.x))
        #expect(paths(.coxeter)["q"] == .a(.y))
        #expect(paths(.sphereFold)["minRadius"] == .a(.x))
        #expect(paths(.sphereFold)["fixedRadius"] == .a(.y))
        #expect(paths(.tiling)["axisMask"] == .b(.xyz))
        #expect(paths(.handAttract)["center"] == .a(.xyz))
        #expect(paths(.handAttract)["radius"] == .a(.w))
        #expect(paths(.handAttract)["ballScale"] == .b(.x))
        #expect(paths(.handAttract)["softness"] == .b(.y))
        #expect(paths(.handAttract)["pocketSize"] == .b(.z))
        #expect(paths(.handAttract)["pocketSoftness"] == .b(.w))
        #expect(paths(.handAttract)["pocketEnabled"] == .flagBit(0))
        #expect(paths(.forearmCarve)["start"] == .a(.xyz))
        #expect(paths(.forearmCarve)["end"] == .b(.xyz))
        #expect(paths(.forearmCarve)["radius"] == .a(.w))
        #expect(paths(.forearmCarve)["softness"] == .b(.w))
        #expect(paths(.bounding)["scale"] == .a(.y))
        #expect(paths(.bounding)["softness"] == .a(.z))
    }

    @Test("Payload fields mint warp.slotN.field keys via the sanctioned factory")
    func payloadFieldKeys() {
        let strength = WarpKind.twist.payloadFields[0]
        #expect(strength.paramKey(slot: 3) == ParamKey.warp(slot: 3, field: "strength"))
        #expect(strength.paramKey(slot: 3).rawValue == "warp.slot3.strength")
        let axis = WarpKind.twist.payloadFields[1]
        #expect(axis.paramKey(slot: 0).rawValue == "warp.slot0.axis")
        // Path → ParamKind mapping for catalog registration.
        #expect(WarpPayloadPath.strength.paramKind == .float)
        #expect(WarpPayloadPath.flagBit(0).paramKind == .bool)
        #expect(WarpPayloadPath.a(.xyz).paramKind == .float3)
        #expect(WarpPayloadPath.b(.w).paramKind == .float)
    }
}
