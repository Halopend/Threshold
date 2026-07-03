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

    /// The compositor path must not be declared shipping until a shell
    /// exists — flipping `shipping` without wiring features will then fail
    /// `requiredFeaturesCoverEveryShippingPath`, which is the intended gate.
    @Test func compositorIsNotYetShipping() {
        #expect(!RenderPath.shipping.contains(.compositor))
    }
}
