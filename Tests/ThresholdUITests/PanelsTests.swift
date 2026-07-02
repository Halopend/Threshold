// PanelsTests.swift — non-view logic behind the panels: group ordering for
// the sidebar and the RenderSurface layer contract (no GPU work — config only).

import Testing
import ThresholdCore
@testable import ThresholdUI

@Suite("ControlSidebar group derivation")
struct GroupOrderTests {
    @Test("Groups list every group present, in first-registration order, once")
    func groupsInOrder() {
        let layout = makeTestLayout()  // shape, shape, color, color, color
        let groups = ControlSidebar.groupsInOrder(layout)
        #expect(groups == [.shape, .color])
    }

    @Test("Empty layout yields no groups")
    func emptyLayout() {
        let layout = Catalog().freeze(dynamicArenaSlots: 0)
        #expect(ControlSidebar.groupsInOrder(layout).isEmpty)
    }
}

#if os(macOS)
import QuartzCore

@MainActor
@Suite("RenderSurface")
struct RenderSurfaceTests {
    @Test("Layer is configured with the pinned session defaults")
    func layerConfiguration() {
        let surface = RenderSurface()
        #expect(surface.layer.pixelFormat == .bgra8Unorm)
        #expect(surface.layer.framebufferOnly == false)
        // The hosting view is layer-hosting over the SAME layer instance.
        #expect(surface.view.layer === surface.layer)
    }
}
#endif
