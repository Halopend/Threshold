// RenderSurface.swift — the macOS live-render host: an NSView backed by a
// CAMetalLayer, plus the SwiftUI wrapper. The render session attaches to
// `layer` and presents into it; this file owns ONLY presentation plumbing
// (layer config, contentsScale-aware drawableSize) — no frame logic, no time.
//
// NOTE: the pinned `InteractiveSession.configure(layer:)` API from the
// concurrent session agent has not landed in ThresholdRender yet, so the
// layer is configured here directly with the pinned defaults
// (`framebufferOnly = false`, `pixelFormat = .bgra8Unorm`, default device).
// When InteractiveSession lands, init should call it instead.

#if os(macOS)

import AppKit
import Metal
import QuartzCore
import SwiftUI

// MARK: - RenderSurface

/// Owns the CAMetalLayer and its hosting NSView. Create once per window,
/// hand `layer` to the render session, and place `RenderSurfaceView(surface:)`
/// in the SwiftUI hierarchy.
@MainActor
public final class RenderSurface {
    /// The layer the render session draws into.
    public let layer: CAMetalLayer
    /// The hosting view (also what `RenderSurfaceView` wraps).
    public let view: NSView

    public init() {
        let layer = CAMetalLayer()
        // Inline InteractiveSession.configure(layer:) stand-in — see header.
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
        layer.device = MTLCreateSystemDefaultDevice()
        self.layer = layer
        self.view = MetalLayerHostView(metalLayer: layer)
    }
}

// MARK: - MetalLayerHostView

/// Layer-hosting NSView that keeps `drawableSize` in sync with view bounds
/// and the window's backing scale (Retina-aware; tracks display moves).
final class MetalLayerHostView: NSView {
    private let metalLayer: CAMetalLayer

    init(metalLayer: CAMetalLayer) {
        self.metalLayer = metalLayer
        super.init(frame: .zero)
        wantsLayer = true
        layer = metalLayer
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        updateDrawableSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDrawableSize()
    }

    /// Fires on backing-scale changes (window dragged between displays).
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? metalLayer.contentsScale
        guard scale > 0 else { return }
        metalLayer.contentsScale = scale
        let size = CGSize(
            width: max(1, bounds.width * scale),
            height: max(1, bounds.height * scale))
        if metalLayer.drawableSize != size {
            metalLayer.drawableSize = size
        }
    }
}

// MARK: - RenderSurfaceView

/// SwiftUI wrapper around a `RenderSurface`. The surface outlives view
/// updates (it is created by the owner, not per-body), so re-renders never
/// tear down the layer the render session is presenting into.
public struct RenderSurfaceView: NSViewRepresentable {
    private let surface: RenderSurface

    public init(surface: RenderSurface) {
        self.surface = surface
    }

    public func makeNSView(context: Context) -> NSView {
        surface.view
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        // Nothing to push — the layer is driven by the render session and
        // resizing is handled by the host view itself.
    }
}

#endif
