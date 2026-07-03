// RenderFeatureTableTests.swift — the feature-table CI check (plan §6.2,
// Invariant 8): a shipping render path missing a required feature is a TEST
// FAILURE, not a device discovery six weeks later.

import Testing

@testable import ThresholdRender

@Suite("Render feature table")
struct RenderFeatureTableTests {
    @Test func requiredFeaturesCoverEveryShippingPath() {
        for feature in RenderFeatureTable.features where feature.requiredOnAll {
            let missing = RenderPath.shipping.subtracting(feature.paths)
            #expect(
                missing.isEmpty,
                "feature '\(feature.id)' is missing on shipping path(s): \(missing.map(\.rawValue).sorted().joined(separator: ", "))")
        }
    }

    @Test func featureIDsAreUnique() {
        let ids = RenderFeatureTable.features.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func tableIsNotEmptyAndListsTheCore() {
        #expect(RenderFeatureTable.features.contains { $0.id == "march.core" })
    }

    /// The compositor shell ships (CompositorSession) — and its one declared
    /// gap is explicit: external DE programs render on the compute paths only
    /// until the raster pipeline links them (spike scope, ADR-001).
    @Test func compositorShipsWithExternalDEsAsTheDeclaredGap() {
        #expect(RenderPath.shipping.contains(.compositor))
        let external = RenderFeatureTable.features.first { $0.id == "de.external" }
        #expect(external?.paths.contains(.compositor) == false)
        #expect(external?.requiredOnAll == false,
                "the gap must be declared, not silently absent from the table")
    }
}
