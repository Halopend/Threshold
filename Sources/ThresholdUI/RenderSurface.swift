// RenderSurface.swift — the live-render host: a platform view backed by a
// CAMetalLayer (NSView on macOS, UIView on iOS/iPadOS), plus the SwiftUI
// wrapper. The render session attaches to `layer` and presents into it; this
// file owns ONLY presentation plumbing (layer config, contentsScale-aware
// drawableSize) — no frame logic, no time. visionOS has no CAMetalLayer
// window path here — it gets the Compositor Services shell (ADR-001).
//
// The compute-into-drawable layer contract (`framebufferOnly = false`,
// `pixelFormat = .bgra8Unorm`) is owned by `InteractiveSession.configure`, the
// single source of truth — `init` calls it so the surface and the session can
// never disagree. The device is the system default (matching GPUContext).

#if os(macOS)

import AppKit
import Metal
import QuartzCore
import SwiftUI
import ThresholdRender

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
        InteractiveSession.configure(layer: layer)  // single source of truth
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

#elseif os(iOS)

import Metal
import QuartzCore
import SwiftUI
import ThresholdRender
import UIKit

// MARK: - RenderSurface (UIKit)

/// Owns the CAMetalLayer and its hosting UIView — same contract as the
/// macOS variant: create once per window, hand `layer` to the render session,
/// place `RenderSurfaceView(surface:)` in the SwiftUI hierarchy.
@MainActor
public final class RenderSurface {
    /// The layer the render session draws into.
    public let layer: CAMetalLayer
    /// The hosting view (also what `RenderSurfaceView` wraps).
    public let view: UIView

    public init() {
        let host = MetalLayerHostView()
        InteractiveSession.configure(layer: host.metalLayer)  // single source of truth
        host.metalLayer.device = MTLCreateSystemDefaultDevice()
        self.layer = host.metalLayer
        self.view = host
    }
}

// MARK: - MetalLayerHostView (UIKit)

/// UIView whose backing layer IS the CAMetalLayer (`layerClass`), keeping
/// `drawableSize` in sync with bounds and the screen's display scale.
final class MetalLayerHostView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateDrawableSize()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateDrawableSize()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = traitCollection.displayScale > 0
            ? traitCollection.displayScale
            : metalLayer.contentsScale
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

// MARK: - RenderSurfaceView (UIKit)

/// SwiftUI wrapper around a `RenderSurface`. The surface outlives view
/// updates (it is created by the owner, not per-body), so re-renders never
/// tear down the layer the render session is presenting into.
public struct RenderSurfaceView: UIViewRepresentable {
    private let surface: RenderSurface

    public init(surface: RenderSurface) {
        self.surface = surface
    }

    public func makeUIView(context: Context) -> UIView {
        surface.view
    }

    public func updateUIView(_ uiView: UIView, context: Context) {
        // Nothing to push — the layer is driven by the render session and
        // resizing is handled by the host view itself.
    }
}

#endif
