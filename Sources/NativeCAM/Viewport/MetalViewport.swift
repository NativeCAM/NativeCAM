// MetalViewport: the NativeCAM 3D workspace view (SwiftUI wrapper around a Metal MTKView).
//
// Usage:
//
//     @State private var viewPreset: ViewPreset? = nil
//     @State private var fitCounter = 0
//
//     MetalViewport(scene: viewportScene, preset: $viewPreset, fitRequest: fitCounter)
//
//   - scene:      Value rebuilt by the app on every change. The renderer diffs `geometryVersion` and
//                 `heightField?.version` (plus stock/grid/tool parameters) and only re-uploads what changed.
//   - preset:     Set to .top / .front / .iso to animate the camera to that view fitted to the stock.
//                 The view resets the binding to nil once it has taken the request.
//   - fitRequest: Any change (e.g. `fitCounter += 1`) re-fits the camera to the stock, keeping the orientation.
//                 Optional; defaults to 0.
//
// Default view is iso fitted to the stock. While the user has not moved the camera, a stock-size change
// re-fits automatically.
//
// Mouse / trackpad (Mac conventions):
//   click a shape                     select it (shift/command-click adds or removes)
//   drag a shape                      move the selection (one undo step, committed on mouse-up)
//   drag empty canvas                 marquee select in Top view, orbit in 3D views
//   option + drag                     orbit in any view
//   right-click / control-click       context menu (right-drag pans)
//   middle drag, two-finger scroll    pan
//   scroll wheel, pinch,
//   command + trackpad scroll         zoom towards the cursor
//   trackpad two-finger rotate        spin about Z
//   arrows / delete / escape          nudge / delete / deselect; Edit menu cut/copy/paste/select all work here
//
// Drawing is on demand (paused MTKView + setNeedsDisplay); it only runs at display rate during camera
// animations. Offscreen rendering for tests: `ViewportRenderer.snapshot(scene:width:height:preset:)`.

import AppKit
import CAMCore
import MetalKit
import SwiftUI
import simd

struct MetalViewport: NSViewRepresentable {
    var scene: ViewportScene
    @Binding var preset: ViewPreset?
    var fitRequest: Int
    var interaction: ViewportInteractionDelegate?

    init(scene: ViewportScene, preset: Binding<ViewPreset?>, fitRequest: Int = 0, interaction: ViewportInteractionDelegate? = nil) {
        self.scene = scene
        self._preset = preset
        self.fitRequest = fitRequest
        self.interaction = interaction
    }

    final class Coordinator {
        var lastFitRequest: Int
        var presetResetPending = false
        init(lastFitRequest: Int) { self.lastFitRequest = lastFitRequest }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(lastFitRequest: fitRequest)
    }

    func makeNSView(context: Context) -> ViewportMTKView {
        let view = ViewportMTKView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.interaction = interaction
        view.apply(scene: scene)
        return view
    }

    func updateNSView(_ view: ViewportMTKView, context: Context) {
        view.interaction = interaction
        view.apply(scene: scene)

        let coordinator = context.coordinator
        if fitRequest != coordinator.lastFitRequest {
            coordinator.lastFitRequest = fitRequest
            view.requestFit(preset: nil, animated: true)
        }

        if let requested = preset, !coordinator.presetResetPending {
            view.requestFit(preset: requested, animated: true)
            coordinator.presetResetPending = true
            let binding = $preset
            DispatchQueue.main.async {
                binding.wrappedValue = nil
                coordinator.presetResetPending = false
            }
        }
    }
}

/// MTKView subclass that owns a `ViewportRenderer`, handles camera interaction, and draws on demand.
final class ViewportMTKView: MTKView, MTKViewDelegate {
    let renderer: ViewportRenderer?

    weak var interaction: ViewportInteractionDelegate?

    private enum DragMode { case none, orbit, pan, shapes, marquee, rightPending }
    private var dragMode: DragMode = .none
    private var lastDragPoint: CGPoint = .zero
    private var downPoint: CGPoint = .zero
    private var didDrag = false
    private var panDepth: Float = 1
    private lazy var marqueeLayer: CAShapeLayer = {
        let l = CAShapeLayer()
        let accent = NSColor.controlAccentColor
        l.fillColor = accent.withAlphaComponent(0.15).cgColor
        l.strokeColor = accent.cgColor
        l.lineWidth = 1
        l.isHidden = true
        l.actions = ["path": NSNull(), "hidden": NSNull()]
        layer?.addSublayer(l)
        return l
    }()

    private struct Transition {
        var from: ViewportCamera
        var to: ViewportCamera
        var start: CFTimeInterval
        var duration: CFTimeInterval
    }
    private var transition: Transition?
    private var pendingFit: (preset: ViewPreset?, animated: Bool)? = (.iso, false)
    private var userMovedCamera = false
    private var lastStockSize: SIMD3<Float>?
    private var hasDrawnFrame = false

    private static let orbitRadiansPerPoint: Float = 0.0075

    init(frame: NSRect) {
        let device = MTLCreateSystemDefaultDevice()
        renderer = ViewportRenderer(device: device)
        super.init(frame: frame, device: device)
        colorPixelFormat = ViewportRenderer.colorPixelFormat
        depthStencilPixelFormat = ViewportRenderer.depthPixelFormat
        sampleCount = ViewportRenderer.sampleCount
        clearColor = ViewportRenderer.clearColor
        clearDepth = 0  // reversed Z
        colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        framebufferOnly = true
        autoResizeDrawable = true
        preferredFramesPerSecond = 120
        isPaused = true
        enableSetNeedsDisplay = true
        delegate = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - API used by MetalViewport

    func apply(scene: ViewportScene) {
        guard let renderer else { return }
        renderer.update(scene: scene)
        if let last = lastStockSize, last != scene.stockSize, !userMovedCamera, pendingFit == nil {
            pendingFit = (nil, true)
        }
        lastStockSize = scene.stockSize
        requestRedraw()
    }

    /// Fit the camera to the stock, re-oriented to `preset` if given. Resolved at the next draw, when the
    /// view's aspect ratio is known.
    func requestFit(preset: ViewPreset?, animated: Bool) {
        pendingFit = (preset, animated)
        requestRedraw()
    }

    private func requestRedraw() {
        needsDisplay = true
    }

    // MARK: - Drawing

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        requestRedraw()
    }

    func draw(in view: MTKView) {
        guard let renderer else { return }
        let size = drawableSize
        guard size.width >= 1, size.height >= 1 else { return }
        let aspect = Float(size.width / size.height)

        if let fit = pendingFit {
            pendingFit = nil
            let target = renderer.fittedCamera(preset: fit.preset, aspect: aspect)
            // Never animate before the first frame: there is no previous view to fly from.
            if fit.animated && hasDrawnFrame {
                startTransition(to: target)
            } else {
                transition = nil
                renderer.camera = target
            }
            userMovedCamera = false
        }
        if let t = transition {
            let raw = (CACurrentMediaTime() - t.start) / t.duration
            if raw >= 1 {
                renderer.camera = t.to
                transition = nil
                stopAnimating()
            } else {
                let x = Float(max(raw, 0))
                let eased = x * x * (3 - 2 * x)
                renderer.camera = ViewportCamera.interpolate(t.from, t.to, eased)
            }
        }

        guard let rpd = currentRenderPassDescriptor, let drawable = currentDrawable,
              let cb = renderer.commandQueue.makeCommandBuffer() else { return }
        rpd.depthAttachment.clearDepth = 0
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        renderer.encode(enc, pixelSize: SIMD2(Float(size.width), Float(size.height)))
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
        hasDrawnFrame = true
    }

    private func startTransition(to target: ViewportCamera) {
        guard let renderer else { return }
        var from = renderer.camera
        from.normalizeAngles()
        transition = Transition(from: from, to: target, start: CACurrentMediaTime(), duration: 0.35)
        // Run at display rate until the animation ends.
        enableSetNeedsDisplay = false
        isPaused = false
    }

    private func stopAnimating() {
        isPaused = true
        enableSetNeedsDisplay = true
    }

    private func cameraWillChangeByUser() {
        if transition != nil {
            transition = nil
            stopAnimating()
        }
        pendingFit = nil
        userMovedCamera = true
    }

    // MARK: - Geometry helpers

    private func viewPoint(_ event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    private var viewAspect: Float {
        let b = bounds.size
        return b.height > 0 ? Float(b.width / b.height) : 1
    }

    private func ndc(_ p: CGPoint) -> SIMD2<Float> {
        let b = bounds.size
        guard b.width > 0, b.height > 0 else { return .zero }
        return SIMD2(Float(p.x / b.width) * 2 - 1, Float(p.y / b.height) * 2 - 1)
    }

    /// Design-space point (on the material plane) under a view point.
    private func worldPoint(_ p: CGPoint) -> Vec2 {
        guard let renderer else { return .zero }
        let w = renderer.pickPoint(ndc: ndc(p), aspect: viewAspect)
        return Vec2(Double(w.x), Double(w.y))
    }

    /// World distance covered by `points` screen points near `p` (pick tolerance).
    private func worldTolerance(at p: CGPoint, points: CGFloat = 6) -> Double {
        let a = worldPoint(p), b = worldPoint(CGPoint(x: p.x + points, y: p.y))
        return max(a.distance(to: b), 1e-3)
    }

    private var isTopView: Bool { (renderer?.camera.elevation ?? 0) > 1.4 }

    /// Depth (along the view direction) of the point under the cursor; sets pan speed so the grabbed
    /// point tracks the cursor.
    private func depthUnderCursor(_ p: CGPoint) -> Float {
        guard let renderer else { return 1 }
        let cam = renderer.camera
        let hit = renderer.pickPoint(ndc: ndc(p), aspect: viewAspect)
        let depth = simd_dot(hit - cam.eye, cam.forward)
        return min(max(depth, cam.distance * 0.05), cam.distance * 20)
    }

    // MARK: - Camera operations

    private func orbit(dx: Float, dy: Float) {
        guard let renderer else { return }
        cameraWillChangeByUser()
        var cam = renderer.camera
        cam.azimuth -= dx * Self.orbitRadiansPerPoint
        cam.elevation -= dy * Self.orbitRadiansPerPoint
        cam.normalizeAngles()
        renderer.camera = cam
        requestRedraw()
    }

    /// Pan so the scene moves by (dx, dy) points (y up) at `depth`.
    private func pan(dx: Float, dy: Float, depth: Float) {
        guard let renderer, bounds.height > 0 else { return }
        cameraWillChangeByUser()
        var cam = renderer.camera
        let worldPerPoint = 2 * depth * tan(cam.fovY * 0.5) / Float(bounds.height)
        cam.target -= cam.right * (dx * worldPerPoint) + cam.up * (dy * worldPerPoint)
        renderer.camera = cam
        requestRedraw()
    }

    /// Scale the camera distance by `factor` (< 1 zooms in) about the world point under `p`.
    private func zoom(factor rawFactor: Float, at p: CGPoint) {
        guard let renderer, rawFactor.isFinite, rawFactor > 0 else { return }
        cameraWillChangeByUser()
        var cam = renderer.camera
        let newDistance = min(max(cam.distance * rawFactor, ViewportCamera.distanceRange.lowerBound),
                              ViewportCamera.distanceRange.upperBound)
        let factor = newDistance / cam.distance
        let anchor = renderer.pickPoint(ndc: ndc(p), aspect: viewAspect)
        cam.target = anchor + (cam.target - anchor) * factor
        cam.distance = newDistance
        renderer.camera = cam
        requestRedraw()
    }

    // MARK: - Events

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = viewPoint(event)
        let mods = event.modifierFlags
        downPoint = p
        lastDragPoint = p
        didDrag = false
        if mods.contains(.control) {
            showContextMenu(event)
            dragMode = .none
            return
        }
        if mods.contains(.option) {
            dragMode = .orbit
            return
        }
        if let interaction, interaction.viewportMouseDown(at: worldPoint(p), tolerance: worldTolerance(at: p), modifiers: mods) {
            dragMode = .shapes
            return
        }
        dragMode = isTopView ? .marquee : .orbit
    }

    override func mouseDragged(with event: NSEvent) {
        let p = viewPoint(event)
        if !didDrag, hypot(p.x - downPoint.x, p.y - downPoint.y) < 3 { return }
        didDrag = true
        switch dragMode {
        case .shapes:
            interaction?.viewportDragMoved(to: worldPoint(p))
            lastDragPoint = p
        case .marquee:
            lastDragPoint = p
            let r = CGRect(x: min(p.x, downPoint.x), y: min(p.y, downPoint.y),
                           width: abs(p.x - downPoint.x), height: abs(p.y - downPoint.y))
            marqueeLayer.frame = bounds
            marqueeLayer.path = CGPath(rect: r, transform: nil)
            marqueeLayer.isHidden = false
        default:
            continueDrag(event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let p = viewPoint(event)
        switch dragMode {
        case .shapes:
            interaction?.viewportDragEnded(at: worldPoint(p), moved: didDrag, clickCount: event.clickCount, modifiers: event.modifierFlags)
        case .marquee:
            marqueeLayer.isHidden = true
            if didDrag {
                let corners = [downPoint, CGPoint(x: p.x, y: downPoint.y), p, CGPoint(x: downPoint.x, y: p.y)]
                interaction?.viewportMarquee(corners.map(worldPoint), modifiers: event.modifierFlags)
            } else {
                interaction?.viewportClickedEmpty(modifiers: event.modifierFlags)
            }
        case .orbit:
            if !didDrag { interaction?.viewportClickedEmpty(modifiers: event.modifierFlags) }
        default:
            break
        }
        dragMode = .none
    }

    // Right button: click = context menu (Mac convention), drag = pan.
    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        downPoint = viewPoint(event)
        lastDragPoint = downPoint
        didDrag = false
        dragMode = .rightPending
    }

    override func rightMouseDragged(with event: NSEvent) {
        let p = viewPoint(event)
        if dragMode == .rightPending {
            guard hypot(p.x - downPoint.x, p.y - downPoint.y) >= 3 else { return }
            dragMode = .pan
            didDrag = true
            panDepth = depthUnderCursor(downPoint)
        }
        continueDrag(event)
    }

    override func rightMouseUp(with event: NSEvent) {
        if dragMode == .rightPending { showContextMenu(event) }
        dragMode = .none
    }

    override func otherMouseDown(with event: NSEvent) { beginDrag(event, mode: .pan) }
    override func otherMouseDragged(with event: NSEvent) { continueDrag(event) }
    override func otherMouseUp(with event: NSEvent) { dragMode = .none }

    private func showContextMenu(_ event: NSEvent) {
        let p = viewPoint(event)
        guard let menu = interaction?.viewportMenu(at: worldPoint(p), tolerance: worldTolerance(at: p)) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func beginDrag(_ event: NSEvent, mode: DragMode) {
        window?.makeFirstResponder(self)
        dragMode = mode
        lastDragPoint = viewPoint(event)
        if mode == .pan { panDepth = depthUnderCursor(lastDragPoint) }
    }

    private func continueDrag(_ event: NSEvent) {
        let p = viewPoint(event)
        let dx = Float(p.x - lastDragPoint.x), dy = Float(p.y - lastDragPoint.y)
        lastDragPoint = p
        guard dx != 0 || dy != 0 else { return }
        switch dragMode {
        case .orbit: orbit(dx: dx, dy: dy)
        case .pan: pan(dx: dx, dy: dy, depth: panDepth)
        default: break
        }
    }

    // MARK: - Keyboard and Edit menu (standard responder-chain actions)

    override func keyDown(with event: NSEvent) {
        if interaction?.viewportKeyDown(event) == true { return }
        super.keyDown(with: event)
    }

    override func selectAll(_ sender: Any?) { interaction?.viewportPerform(.selectAll) }
    @objc func delete(_ sender: Any?) { interaction?.viewportPerform(.delete) }
    @objc func copy(_ sender: Any?) { interaction?.viewportPerform(.copy) }
    @objc func cut(_ sender: Any?) { interaction?.viewportPerform(.cut) }
    @objc func paste(_ sender: Any?) { interaction?.viewportPerform(.paste) }
    @objc func duplicate(_ sender: Any?) { interaction?.viewportPerform(.duplicate) }
    override func cancelOperation(_ sender: Any?) { interaction?.viewportPerform(.deselect) }

    override func scrollWheel(with event: NSEvent) {
        let p = viewPoint(event)
        let dx = Float(event.scrollingDeltaX), dy = Float(event.scrollingDeltaY)
        if event.hasPreciseScrollingDeltas {
            if event.modifierFlags.contains(.command) {
                zoom(factor: exp(-dy * 0.01), at: p)
            } else {
                // Trackpad: content follows the fingers.
                pan(dx: dx, dy: -dy, depth: depthUnderCursor(p))
            }
        } else {
            // Mouse wheel: line deltas.
            guard dy != 0 else { return }
            zoom(factor: pow(0.88, dy), at: p)
        }
    }

    override func magnify(with event: NSEvent) {
        let m = Float(event.magnification)
        zoom(factor: 1 / max(1 + m, 0.05), at: viewPoint(event))
    }

    override func rotate(with event: NSEvent) {
        orbit(dx: Float(event.rotation) * (Float.pi / 180) / Self.orbitRadiansPerPoint, dy: 0)
    }
}

extension ViewportMTKView: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let interaction else { return false }
        switch menuItem.action {
        case #selector(selectAll(_:)): return interaction.viewportCanPerform(.selectAll)
        case #selector(delete(_:)): return interaction.viewportCanPerform(.delete)
        case #selector(copy(_:)): return interaction.viewportCanPerform(.copy)
        case #selector(cut(_:)): return interaction.viewportCanPerform(.cut)
        case #selector(paste(_:)): return interaction.viewportCanPerform(.paste)
        case #selector(duplicate(_:)): return interaction.viewportCanPerform(.duplicate)
        default: return true
        }
    }
}
