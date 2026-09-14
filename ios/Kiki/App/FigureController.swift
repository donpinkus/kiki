import CanvasModule
import Foundation
import Observation
import os
import UIKit

private let figureLog = Logger(subsystem: "com.kiki.app", category: "Figure")

/// Posable 3D figure (owner spec 2026-09-13): a person button drops a rigged
/// body onto the canvas as a REFERENCE layer — visible while drawing, excluded
/// from the AI capture, never painted on, re-posable from the layer menu.
///
/// Pose mode is modal (Done/Cancel bar, like the paste float): the live
/// SceneKit overlay covers the canvas document rect and owns every touch.
/// A NEW figure only becomes a layer on Done (Cancel leaves the stack
/// untouched); EDITING an existing figure hides the layer's baked pixels on
/// screen while the overlay stands in, then Done re-bakes into the same layer.
@MainActor
@Observable
final class FigureController {
    struct Session {
        let overlay: FigurePoseOverlayView
        /// nil → a new figure (layer created on Done).
        let editingLayerID: UUID?
    }

    private(set) var session: Session?
    var isPosing: Bool { session != nil }
    var isEditingExisting: Bool { session?.editingLayerID != nil }

    /// Body used for new figures + the live picker. Persisted only when the
    /// user changes it during a session — `beginEditing` sets it to the edited
    /// figure's body without touching the preference.
    var body: FigureBody {
        didSet {
            guard body != oldValue, let session else { return }
            do {
                try session.overlay.setBody(body)
            } catch {
                onMessage?("Couldn't load that body — keeping the current one.")
                body = oldValue
                return
            }
            UserDefaults.standard.set(body.rawValue, forKey: Self.bodyDefaultsKey)
        }
    }

    /// Pose mode may only start from a settled canvas: no paste/Move float
    /// (the overlay would sit above it and Done would commit the float into the
    /// figure layer) and no AI Edit preview. `DrawingTopBar` disables the
    /// button on the same rule; AI Edit state is gated by the coordinator.
    var canBegin: Bool {
        guard !isPosing, let canvasViewModel else { return false }
        return !canvasViewModel.hasTransientFloat
    }
    private static let bodyDefaultsKey = "figure.body"

    /// The canvas the figure lands on (set by AppCoordinator).
    weak var canvasViewModel: CanvasViewModel?
    /// Transient user-facing message sink (AppCoordinator's banner).
    var onMessage: ((String) -> Void)?

    init() {
        body = UserDefaults.standard.string(forKey: Self.bodyDefaultsKey)
            .flatMap(FigureBody.init(rawValue:)) ?? .male
        // Pose thumbnails + their scenes are a pure cache — drop them under pressure.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in FigurePoseLibrary.purge() }
        }
    }

    // MARK: - Entry points

    /// Person button: start posing a fresh figure in the default stance.
    func beginNewFigure() {
        guard canBegin, let canvasViewModel else { return }
        guard canvasViewModel.layers.count < 16 else {
            onMessage?("Layer limit reached — delete a layer first.")
            return
        }
        guard let scene = makeScene(body) else { return }
        var pose = FigurePose()
        pose.body = scene.body
        scene.applyPlacement(pose)
        scene.applyDefaultPose(into: &pose)
        install(scene: scene, pose: pose, editing: nil)
        Analytics.track(.figureAdded, properties: ["body": pose.body.rawValue])
    }

    /// Layer menu → Edit Pose: reopen an existing figure layer.
    func beginEditing(layer: LayerInfo) {
        guard canBegin, layer.isReference else { return }
        // A missing/corrupt payload starts from the default stance; an EMPTY
        // joints map is a legitimate saved pose (T-pose) and is kept as is.
        let saved = FigurePose.decode(layer.referenceData)
        var pose = saved ?? FigurePose()
        guard let scene = makeScene(pose.body) else { return }
        if saved == nil {
            scene.applyPlacement(pose)
            scene.applyDefaultPose(into: &pose)
        }
        body = pose.body
        install(scene: scene, pose: pose, editing: layer.id)
        Analytics.track(.figureEditOpened)
    }

    /// Done: bake the figure at document resolution into its reference layer.
    /// Recoverable failures (render, layer cap) keep the session alive so the
    /// user can fix the cause and tap Done again.
    func commit() {
        guard let session, let canvasViewModel else { return }
        let overlay = session.overlay
        guard let image = overlay.figure.render() else {
            onMessage?("Couldn't render the figure — try again.")
            return
        }
        let data = overlay.pose.encoded()
        if let id = session.editingLayerID {
            // The edited layer must still exist (undo / delete are disabled
            // while posing, but never silently re-create it as a new layer).
            guard let index = canvasViewModel.layers.firstIndex(where: { $0.id == id }) else {
                onMessage?("That figure layer is gone — pose discarded.")
                teardown()
                return
            }
            canvasViewModel.setLayerImage(image, data: data, at: index)
        } else if canvasViewModel.addReferenceLayer(image: image, name: nextLayerName(), data: data) == nil {
            if canvasViewModel.layers.count >= 16 {
                onMessage?("Layer limit reached — delete a layer, then tap Done again.")
            } else {
                onMessage?("Couldn't add the figure layer — try again.")
            }
            return
        }
        Analytics.track(.figurePoseCommitted, properties: [
            "body": overlay.pose.body.rawValue,
            "edit": session.editingLayerID != nil,
            "joints_posed": overlay.pose.joints.count,
        ])
        teardown()
    }

    /// Cancel (or leaving the drawing): drop the edit, nothing touches layers.
    func cancel() {
        guard session != nil else { return }
        Analytics.track(.figurePoseCancelled)
        teardown()
    }

    func resetPose() {
        session?.overlay.resetPose()
    }

    /// Poses picker: load a bundled preset into the live figure.
    func applyPreset(_ preset: FigurePosePreset) {
        session?.overlay.applyPreset(preset)
        Analytics.track(.figurePresetApplied, properties: ["preset": preset.id])
    }

    /// Poses popover visibility (pose bar button).
    var showPosePicker = false

    // MARK: - Internals

    private func makeScene(_ body: FigureBody) -> FigureScene? {
        do {
            return try FigureScene(body: body)
        } catch {
            onMessage?("Couldn't load the figure model.")
            figureLog.error("[figure] load failed: \(String(describing: error))")
            return nil
        }
    }

    private func install(scene: FigureScene, pose: FigurePose, editing: UUID?) {
        guard let canvasViewModel else { return }
        let overlay = FigurePoseOverlayView(figure: scene, pose: pose)
        canvasViewModel.setLayerDisplaySuppressed(id: editing)
        canvasViewModel.setInteractiveOverlay(overlay)
        session = Session(overlay: overlay, editingLayerID: editing)
    }

    private func teardown() {
        canvasViewModel?.setInteractiveOverlay(nil)
        canvasViewModel?.setLayerDisplaySuppressed(id: nil)
        showPosePicker = false
        session = nil
    }

    private func nextLayerName() -> String {
        let n = (canvasViewModel?.layers.filter(\.isReference).count ?? 0) + 1
        return "Figure \(n)"
    }

    // MARK: - Dev automation (simulator)

    #if DEBUG && targetEnvironment(simulator)
    /// `figureDrag:<handle>,<docX>,<docY>` — move a handle to a document point.
    func devDrag(handle: String, to point: CGPoint) {
        session?.overlay.dragHandle(id: handle, toDoc: point)
    }

    /// Current joint deltas as pose-file JSON (author presets from the sim).
    var devPoseJSON: String {
        guard let pose = session?.overlay.pose,
              let data = try? JSONSerialization.data(withJSONObject: pose.joints.mapValues { $0.map { Double($0) } },
                                                     options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    var devPoseSummary: String {
        guard let pose = session?.overlay.pose else { return "not posing" }
        let handles = session?.overlay.figure.handleDocPositions()
            .map { "\($0.handle.id)=(\(Int($0.point.x)),\(Int($0.point.y)))" }
            .joined(separator: " ") ?? ""
        return "body=\(pose.body.rawValue) center=(\(Int(pose.centerX)),\(Int(pose.centerY))) h=\(Int(pose.heightPx)) yaw=\(pose.yaw) pitch=\(pose.pitch) roll=\(pose.roll) joints=\(pose.joints.count) \(handles)"
    }
    #endif
}
