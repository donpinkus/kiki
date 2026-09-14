import CanvasModule
import SceneKit
import UIKit

/// The pose editor's canvas-space overlay: covers the document rect (installed
/// via `CanvasViewModel.setInteractiveOverlay`, so it follows canvas pan/zoom),
/// shows the live SceneKit figure, draws joint handles, and owns every touch
/// while pose mode is active.
///
/// Interaction (owner-approved 2026-09-13):
/// - one finger / pencil on a handle → pose that joint (IK for hands/feet,
///   swing for elbows/knees/chest/head, pelvis moves the whole figure)
/// - one finger on empty space → orbit (turntable yaw + tilt pitch)
/// - two fingers → move / pinch-scale / twist-roll the whole figure
@MainActor
final class FigurePoseOverlayView: UIView, UIGestureRecognizerDelegate {
    let figure: FigureScene
    private(set) var pose: FigurePose
    /// Fires after every pose change (the bar's Reset/Done state, dev logging).
    var onPoseChanged: (() -> Void)?

    private let scnView = SCNView()
    private var handleShapes: [String: CAShapeLayer] = [:]
    private var handlePoints: [(handle: FigureRig.Handle, point: CGPoint)] = []

    private enum Drag { case handle(FigureRig.Handle), orbit }
    private var activeTouch: UITouch?
    private var drag: Drag?
    private var lastPoint: CGPoint = .zero

    private let pinch = UIPinchGestureRecognizer()
    private let rotation = UIRotationGestureRecognizer()
    private let pan = UIPanGestureRecognizer()

    /// Handle hit radius / dot radius in SCREEN points. The overlay lives inside
    /// the zoomed `transformView`, so both are divided by the current canvas
    /// zoom (`screenZoom`) to stay constant on screen.
    private let hitRadius: CGFloat = 26
    private let handleRadius: CGFloat = 9

    /// Screen points per overlay point (the canvas zoom this overlay sits under).
    private var screenZoom: CGFloat {
        let a = convert(CGPoint.zero, to: nil)
        let b = convert(CGPoint(x: 1, y: 0), to: nil)
        let z = hypot(b.x - a.x, b.y - a.y)
        return z > 1e-3 ? z : 1
    }

    init(figure: FigureScene, pose: FigurePose) {
        self.figure = figure
        self.pose = pose
        super.init(frame: .zero)
        backgroundColor = .clear
        isMultipleTouchEnabled = true

        scnView.scene = figure.scene
        scnView.pointOfView = figure.cameraNode
        scnView.backgroundColor = .clear
        scnView.isOpaque = false
        scnView.allowsCameraControl = false
        scnView.autoenablesDefaultLighting = false
        scnView.antialiasingMode = .multisampling4X
        // Change-driven rendering (SceneKit redraws when node transforms change);
        // a continuous 60 fps loop would burn GPU while the user just looks.
        scnView.rendersContinuously = false
        scnView.preferredFramesPerSecond = 60
        scnView.isUserInteractionEnabled = false
        scnView.frame = bounds
        scnView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(scnView)

        for h in FigureRig.handles {
            let shape = CAShapeLayer()
            shape.fillColor = UIColor.white.withAlphaComponent(0.92).cgColor
            shape.strokeColor = UIColor(red: 0.13, green: 0.55, blue: 1.0, alpha: 1).cgColor
            shape.lineWidth = 2
            shape.shadowColor = UIColor.black.cgColor
            shape.shadowOpacity = 0.35
            shape.shadowRadius = 2
            shape.shadowOffset = CGSize(width: 0, height: 1)
            layer.addSublayer(shape)
            handleShapes[h.id] = shape
        }

        for g in [pinch, rotation, pan] as [UIGestureRecognizer] {
            g.delegate = self
            g.cancelsTouchesInView = false
            g.delaysTouchesBegan = false
            addGestureRecognizer(g)
        }
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        pinch.addTarget(self, action: #selector(handlePinch(_:)))
        rotation.addTarget(self, action: #selector(handleRotation(_:)))
        pan.addTarget(self, action: #selector(handlePan(_:)))

        figure.apply(pose)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        refreshHandles()
    }

    // MARK: - Pose mutation

    func setPose(_ newPose: FigurePose) {
        pose = newPose
        figure.apply(pose)
        poseDidChange()
    }

    func setBody(_ body: FigureBody) throws {
        try figure.setBody(body, pose: &pose)
        poseDidChange()
    }

    /// Replace the joints with a preset (placement/body kept; a preset yaw
    /// turns the figure to the pose's intended view).
    func applyPreset(_ preset: FigurePosePreset) {
        pose.joints = preset.joints
        if let yaw = preset.yaw { pose.yaw = yaw }
        figure.apply(pose)
        poseDidChange()
    }

    func resetPose() {
        figure.applyDefaultPose(into: &pose)
        pose.yaw = 0
        pose.pitch = 0
        pose.roll = 0
        figure.applyPlacement(pose)
        poseDidChange()
    }

    /// Drag a handle by id to a document point (dev automation + tests).
    func dragHandle(id: String, toDoc target: CGPoint) {
        guard let h = FigureRig.handles.first(where: { $0.id == id }) else { return }
        moveHandle(h, toDoc: target)
    }

    private func moveHandle(_ handle: FigureRig.Handle, toDoc target: CGPoint) {
        if case .translate = handle.action {
            guard let current = figure.handleWorldPosition(handle) else { return }
            let now = figure.docPoint(ofWorld: current)
            pose.centerX += target.x - now.x
            pose.centerY += target.y - now.y
            figure.applyPlacement(pose)
        } else if figure.drag(handle, toDoc: target) {
            figure.readJoints(into: &pose)
        }
        poseDidChange()
    }

    private func poseDidChange() {
        refreshHandles()
        onPoseChanged?()
    }

    // MARK: - Coordinates

    private var docPerPoint: CGFloat {
        bounds.width > 0 ? CGFloat(FigureScene.documentSide) / bounds.width : 1
    }

    private func docPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * docPerPoint, y: p.y * docPerPoint)
    }

    private func viewPoint(_ doc: CGPoint) -> CGPoint {
        CGPoint(x: doc.x / docPerPoint, y: doc.y / docPerPoint)
    }

    private func refreshHandles() {
        handlePoints = figure.handleDocPositions()
        let zoom = screenZoom
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (h, doc) in handlePoints {
            guard let shape = handleShapes[h.id] else { continue }
            let c = viewPoint(doc)
            let r: CGFloat = (h.id == "pelvis" ? handleRadius * 1.35 : handleRadius) / zoom
            shape.lineWidth = 2 / zoom
            let active = { if case .handle(let a)? = self.drag { return a.id == h.id } else { return false } }()
            shape.path = UIBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)).cgPath
            shape.fillColor = (active ? UIColor(red: 0.13, green: 0.55, blue: 1.0, alpha: 1) : UIColor.white.withAlphaComponent(0.92)).cgColor
        }
        CATransaction.commit()
    }

    private func handle(near p: CGPoint) -> FigureRig.Handle? {
        var best: (FigureRig.Handle, CGFloat)?
        let radius = hitRadius / screenZoom
        for (h, doc) in handlePoints {
            let d = hypot(viewPoint(doc).x - p.x, viewPoint(doc).y - p.y)
            if d <= radius, best == nil || d < best!.1 { best = (h, d) }
        }
        return best?.0
    }

    // MARK: - Single-touch: handles + orbit

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let total = event?.allTouches?.count ?? touches.count
        if activeTouch != nil || total > 1 {
            // A second finger: this is a two-finger transform, not a joint drag.
            endDrag()
            return
        }
        guard let touch = touches.first else { return }
        let p = touch.location(in: self)
        activeTouch = touch
        lastPoint = p
        if let h = handle(near: p) {
            drag = .handle(h)
        } else {
            drag = .orbit
        }
        refreshHandles()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch), let drag else { return }
        let p = touch.location(in: self)
        switch drag {
        case .handle(let h):
            moveHandle(h, toDoc: docPoint(p))
        case .orbit:
            // Full-width drag = half a turn; "grab the surface and pull" sense.
            let k = CGFloat.pi / max(bounds.width, 1)
            pose.yaw += Double((p.x - lastPoint.x) * k)
            pose.pitch = max(-1.2, min(1.2, pose.pitch + Double((p.y - lastPoint.y) * k)))
            figure.applyPlacement(pose)
            poseDidChange()
        }
        lastPoint = p
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let touch = activeTouch, touches.contains(touch) { endDrag() }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let touch = activeTouch, touches.contains(touch) { endDrag() }
    }

    private func endDrag() {
        activeTouch = nil
        drag = nil
        refreshHandles()
    }

    // MARK: - Two-finger: move / scale / roll the whole figure

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        guard g.state == .changed else { return }
        let t = g.translation(in: self)
        pose.centerX += Double(t.x * docPerPoint)
        pose.centerY += Double(t.y * docPerPoint)
        g.setTranslation(.zero, in: self)
        figure.applyPlacement(pose)
        poseDidChange()
    }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        guard g.state == .changed else { return }
        pose.heightPx = max(200, min(6000, pose.heightPx * Double(g.scale)))
        g.scale = 1
        figure.applyPlacement(pose)
        poseDidChange()
    }

    @objc private func handleRotation(_ g: UIRotationGestureRecognizer) {
        guard g.state == .changed else { return }
        pose.roll += Double(g.rotation)
        g.rotation = 0
        figure.applyPlacement(pose)
        poseDidChange()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}
