import AVFoundation
import PhotosUI
import SwiftData
import SwiftUI

/// The Animate screen: turn keyframes (from your drawings or Photos) into a
/// short AI video. Reached from a drawing (its result pre-loaded as the
/// start keyframe) or from the gallery. Layout (landscape iPad):
///
///   ┌ top bar: back · title · availability ────────────────┐
///   │ ┌ preview (player / streamed frames) ┐ ┌ controls ┐  │
///   │ │                                    │ │ keyframes│  │
///   │ │                                    │ │ prompt   │  │
///   │ │                                    │ │ duration │  │
///   │ │                                    │ │ [Animate]│  │
///   │ └────────────────────────────────────┘ └──────────┘  │
///   │ history strip: [▣][▣][▣] …                            │
///   └───────────────────────────────────────────────────────┘
struct AnimateView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Query(sort: \AnimationClip.createdAt, order: .reverse) private var clips: [AnimationClip]

    @State private var pickingSlot: KeyframeSlot?
    @State private var shareItem: ShareItem?
    @State private var elapsedTick = 0
    @FocusState private var motionFieldFocused: Bool

    private let elapsedTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    enum KeyframeSlot: String, Identifiable {
        case start, end
        var id: String { rawValue }
    }

    struct ShareItem: Identifiable {
        let id = UUID()
        let url: URL
    }

    private var controller: AnimateController? { coordinator.animate }

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 8)

            if let controller {
                HStack(alignment: .top, spacing: 16) {
                    preview(controller)
                    controlsPanel(controller)
                        .frame(width: 340)
                }
                .padding(.horizontal, 20)

                historyStrip(controller)
                    .padding(.top, 12)
                    .padding(.bottom, 10)
            } else {
                Spacer()
            }
        }
        .background(Color(.systemGroupedBackground))
        .onAppear {
            coordinator.animate?.screenDidAppear()
            Analytics.track(.animateOpened, properties: [
                "clip_count": clips.count,
            ])
        }
        .onDisappear { coordinator.animate?.screenDidDisappear() }
        .onReceive(elapsedTimer) { _ in
            // Ticks drive the generating elapsed label AND the warm-up
            // countdown box — both need a 1 Hz re-render.
            let warming = controller.map { $0.availability == .warming || $0.availability == .unknown } ?? false
            if controller?.isGenerating == true || warming { elapsedTick += 1 }
        }
        .onChange(of: motionFieldFocused) { _, focused in
            // Auto-open the ideas panel the first time the motion field gains
            // focus; once closed by the user it never auto-opens again — only
            // the "See examples" button brings it back.
            if focused, !UserDefaults.standard.bool(forKey: "animateExamplesDismissed") {
                withAnimation(.easeOut(duration: 0.2)) { controller?.showMotionExamples = true }
            }
        }
        .sheet(item: $pickingSlot) { slot in
            if let controller {
                KeyframePickerSheet(slot: slot, controller: controller)
                    .environment(coordinator)
            }
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(activityItems: [item.url]) { completed in
                if completed {
                    Analytics.track(.animationShared)
                }
            }
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                coordinator.closeAnimate()
            } label: {
                Label("Back", systemImage: "chevron.left")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
            }

            Spacer()

            Text("Animate")
                .font(.title3.weight(.semibold))

            Spacer()

            availabilityChip
        }
    }

    @ViewBuilder
    private var availabilityChip: some View {
        if let controller {
            switch controller.availability {
            case .ready:
                Label("Ready", systemImage: "bolt.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
            case .warming, .unknown:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(warmingLabel(controller))
                        .font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule())
            case .off:
                Label("Unavailable", systemImage: "moon.zzz.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
    }

    /// Warming detail from the availability push: the boot stage tells
    /// "hunting for GPU capacity" (unpredictable) apart from "instance
    /// booting" (has an ETA worth showing).
    private func warmingLabel(_ controller: AnimateController) -> String {
        guard let status = controller.videoSystemStatus else { return "Warming up" }
        switch status.stage {
        case "searching":
            return "Finding a GPU…"
        case "booting":
            if let estimate = status.bootEstimateSeconds,
               let startedMs = status.stageStartedAtMs {
                let elapsed = Date().timeIntervalSince1970 - startedMs / 1000
                let remaining = Double(estimate) - elapsed
                if remaining > 30 {
                    return "Warming up · ~\(Int((remaining / 60).rounded()))m"
                }
                return "Almost ready…"
            }
            return "Warming up"
        default:
            return "Warming up"
        }
    }

    // MARK: - Preview

    private func preview(_ controller: AnimateController) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.secondarySystemGroupedBackground))

            Group {
                if controller.isGenerating, let frame = controller.streamingFrame {
                    Image(uiImage: frame)
                        .resizable()
                        .scaledToFit()
                } else if !controller.isGenerating, let url = controller.playbackURL {
                    AnimateLoopingPlayerView(url: url, isMuted: controller.isMuted)
                        .aspectRatio(1, contentMode: .fit)
                } else if let start = controller.startKeyframe {
                    Image(uiImage: start)
                        .resizable()
                        .scaledToFit()
                        .opacity(controller.isGenerating ? 0.45 : 0.9)
                } else {
                    ContentUnavailableView(
                        "Add a keyframe",
                        systemImage: "photo.badge.plus",
                        description: Text("Pick a drawing or photo on the right, then tap Animate.")
                    )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))

            if controller.isGenerating {
                generatingOverlay(controller)
            }
        }
        .overlay(alignment: .topTrailing) {
            if !controller.isGenerating, let clip = selectedClip(controller) {
                HStack(spacing: 8) {
                    Button {
                        controller.extendFromLastFrame(of: clip)
                    } label: {
                        Label("Extend", systemImage: "arrow.forward.to.line")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .help("Use this clip's last frame as the next start keyframe")
                    Button {
                        if let url = controller.exportURL(for: clip) {
                            shareItem = ShareItem(url: url)
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.body.weight(.medium))
                            .frame(width: 38, height: 38)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                }
                .padding(10)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !controller.isGenerating, controller.playbackURL != nil {
                Button {
                    controller.isMuted.toggle()
                } label: {
                    Image(systemName: controller.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.footnote.weight(.medium))
                        .frame(width: 34, height: 34)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .padding(10)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if !controller.isGenerating, let clip = selectedClip(controller), !controller.showMotionExamples {
                clipCaption(clip)
                    .padding(10)
            }
        }
        .overlay(alignment: .topLeading) {
            if controller.showMotionExamples {
                MotionExamplesPanel(
                    onSelect: { example, isSound in
                        if isSound {
                            controller.audioPrompt = example
                            controller.audioEnabled = true
                        } else {
                            controller.prompt = example
                        }
                    },
                    onClose: {
                        UserDefaults.standard.set(true, forKey: "animateExamplesDismissed")
                        withAnimation(.easeIn(duration: 0.15)) { controller.showMotionExamples = false }
                    }
                )
                .padding(10)
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// What produced the selected clip — makes history browsable by meaning,
    /// not just thumbnails.
    private func clipCaption(_ clip: AnimationClip) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if !clip.prompt.isEmpty {
                Text(clip.prompt)
                    .font(.caption)
                    .lineLimit(2)
            }
            Text("\(Int(clip.durationSeconds.rounded()))s · \(clip.createdAt.formatted(.relative(presentation: .named)))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 9))
        .frame(maxWidth: 320, alignment: .leading)
    }

    private func selectedClip(_ controller: AnimateController) -> AnimationClip? {
        guard let id = controller.selectedClipID else { return nil }
        return clips.first { $0.id == id }
    }

    private func generatingOverlay(_ controller: AnimateController) -> some View {
        let _ = elapsedTick // re-render every second
        let elapsed = controller.generationStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        let expected = controller.expectedWaitSeconds
        return VStack(spacing: 12) {
            if let progress = controller.streamingProgress, progress.total > 0 {
                // Frames are streaming in — real render progress.
                ProgressView(value: Double(progress.index + 1), total: Double(progress.total))
                    .frame(width: 200)
                Text("Rendering \(progress.index + 1)/\(progress.total)")
                    .font(.caption.weight(.medium))
            } else {
                // Waiting on the GPU: determinate bar against the measured
                // typical wait — capped at 95% so it never claims done early.
                ProgressView(value: min(elapsed / expected, 0.95))
                    .frame(width: 200)
                Text("Animating… \(Int(elapsed))s")
                    .font(.caption.weight(.medium))
                Text(elapsed < expected
                     ? "Usually takes about \(Int(expected)) seconds"
                     : "Taking a little longer than usual…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Button("Cancel") {
                controller.cancelGeneration()
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .padding(20)
        .frame(width: 260)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Controls

    private func controlsPanel(_ controller: AnimateController) -> some View {
        @Bindable var controller = controller
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                keyframesSection(controller)
                promptSection(controller)
                soundSection(controller)
                durationSection(controller)
                animateButton(controller)
                warmupInfoBox(controller)
                if let error = controller.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(16)
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func keyframesSection(_ controller: AnimateController) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Keyframes")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                keyframeSlotView(
                    image: controller.startKeyframe,
                    title: "Start",
                    required: true,
                    onEdit: { image in
                        coordinator.forkFrameIntoDrawing(image, returnSlot: .start)
                    }
                ) { pickingSlot = .start } onClear: {
                    controller.startKeyframe = nil
                    controller.sourceDrawingID = nil
                }

                if controller.endKeyframe != nil {
                    // Both slots filled: the arrow becomes a swap (reverses
                    // the morph direction).
                    Button {
                        controller.swapKeyframes()
                    } label: {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.caption.weight(.bold))
                            .frame(width: 28, height: 28)
                            .background(Color(.tertiarySystemGroupedBackground), in: Circle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Image(systemName: "arrow.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                }

                keyframeSlotView(
                    image: controller.endKeyframe,
                    title: "End",
                    required: false,
                    onEdit: { image in
                        coordinator.forkFrameIntoDrawing(image, returnSlot: .end)
                    }
                ) { pickingSlot = .end } onClear: {
                    controller.endKeyframe = nil
                }
            }

            Text(controller.endKeyframe == nil
                 ? "The video starts on your image and the AI imagines the motion. Add an End frame to steer where it lands."
                 : "The video morphs from Start to End over the clip.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func keyframeSlotView(
        image: UIImage?,
        title: String,
        required: Bool,
        onEdit: ((UIImage) -> Void)? = nil,
        onPick: @escaping () -> Void,
        onClear: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 5) {
            Button(action: onPick) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(.tertiarySystemGroupedBackground))
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: "plus")
                            .font(.title3.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 120, height: 90)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color(.separator), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            // Frame forking: long-press a filled slot to edit that frame on
            // the drawing canvas; the edited canvas returns to this slot.
            .contextMenu {
                if let image, let onEdit {
                    Button {
                        onEdit(image)
                    } label: {
                        Label("Edit in canvas", systemImage: "paintbrush.pointed")
                    }
                }
                Button(action: onPick) {
                    Label("Replace…", systemImage: "photo.on.rectangle")
                }
                if image != nil, !required {
                    Button(role: .destructive, action: onClear) {
                        Label("Remove", systemImage: "xmark.circle")
                    }
                }
            }
            .overlay(alignment: .topTrailing) {
                if image != nil, !required {
                    Button(action: onClear) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.body)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .gray)
                    }
                    .offset(x: 7, y: -7)
                }
            }

            Text(required ? title : "\(title) · optional")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    private func promptSection(_ controller: AnimateController) -> some View {
        @Bindable var controller = controller
        return VStack(alignment: .leading, spacing: 8) {
            Text("Motion")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)

            TextField(
                "Gentle motion, camera drifts closer (default)",
                text: $controller.prompt,
                axis: .vertical
            )
            .lineLimit(2...4)
            .textFieldStyle(.plain)
            .focused($motionFieldFocused)
            .padding(10)
            .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))

            Button {
                withAnimation(.easeOut(duration: 0.2)) { controller.showMotionExamples.toggle() }
            } label: {
                Label(
                    controller.showMotionExamples ? "Hide examples" : "See examples",
                    systemImage: "lightbulb"
                )
                .font(.caption.weight(.medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        }
    }

    /// Sound direction, separate from motion: a toggle (off = the server
    /// muxes a silent MP4 — exports too, not just playback) plus its own
    /// prompt box composed into the model prompt server-side.
    private func soundSection(_ controller: AnimateController) -> some View {
        @Bindable var controller = controller
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Sound")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("", isOn: $controller.audioEnabled)
                    .labelsHidden()
                    .controlSize(.mini)
            }

            if controller.audioEnabled {
                TextField(
                    "What should it sound like? (optional)",
                    text: $controller.audioPrompt,
                    axis: .vertical
                )
                .lineLimit(1...3)
                .textFieldStyle(.plain)
                .padding(10)
                .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
            } else {
                Text("Videos will be silent.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func durationSection(_ controller: AnimateController) -> some View {
        @Bindable var controller = controller
        return VStack(alignment: .leading, spacing: 8) {
            Text("Duration")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            Picker("Duration", selection: $controller.durationSeconds) {
                ForEach(AnimateController.durationOptions, id: \.self) { seconds in
                    Text("\(seconds)s").tag(seconds)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private func animateButton(_ controller: AnimateController) -> some View {
        Button {
            controller.generate()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                Text(animateCTA(controller))
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(
                controller.canGenerate ? Color.accentColor : Color(.systemGray4),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .foregroundStyle(controller.canGenerate ? .white : .secondary)
        }
        .disabled(!controller.canGenerate)
    }

    private func animateCTA(_ controller: AnimateController) -> String {
        if controller.isGenerating { return "Animating…" }
        switch controller.availability {
        case .warming, .unknown:
            // Stays "Animate" (disabled) — the warm-up box below the button
            // owns the explanation and countdown.
            return "Animate"
        case .off: return "Unavailable"
        case .ready:
            return controller.startKeyframe == nil ? "Add a keyframe" : "Animate"
        }
    }

    /// Warm-up status under the (disabled) Animate button: a determinate
    /// countdown while the GPU boots (we know the boot estimate + when it
    /// started), an indeterminate "finding a GPU" state while the pool hunts
    /// capacity (genuinely unpredictable — never fake an ETA there), and a
    /// promise that the button unlocks by itself.
    @ViewBuilder
    private func warmupInfoBox(_ controller: AnimateController) -> some View {
        if controller.availability == .warming || controller.availability == .unknown {
            let _ = elapsedTick // re-render every second while warming
            VStack(alignment: .leading, spacing: 8) {
                Label("Video AI is warming up", systemImage: "bolt.badge.clock")
                    .font(.footnote.weight(.semibold))

                if let status = controller.videoSystemStatus,
                   status.stage == "booting",
                   let estimate = status.bootEstimateSeconds, estimate > 0,
                   let startedMs = status.stageStartedAtMs {
                    let elapsed = max(0, Date().timeIntervalSince1970 - startedMs / 1000)
                    let remaining = max(0, Double(estimate) - elapsed)
                    ProgressView(value: min(elapsed, Double(estimate)), total: Double(estimate))
                        .tint(.accentColor)
                    Text(remaining > 75
                         ? "About \(Int((remaining / 60).rounded())) min left"
                         : remaining > 20 ? "About a minute left" : "Almost ready…")
                        .font(.caption.weight(.medium))
                } else if controller.videoSystemStatus?.stage == "searching" {
                    ProgressView()
                        .controlSize(.small)
                    Text("Finding an available GPU — usually a minute or two.")
                        .font(.caption.weight(.medium))
                } else {
                    ProgressView()
                        .controlSize(.small)
                    Text("Getting things started — usually a few minutes.")
                        .font(.caption.weight(.medium))
                }

                Text("You can set up your keyframes and motion now — Animate unlocks automatically.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - History

    @ViewBuilder
    private func historyStrip(_ controller: AnimateController) -> some View {
        if !clips.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(clips) { clip in
                        historyTile(clip, controller: controller)
                    }
                }
                .padding(.horizontal, 20)
            }
            .frame(height: 84)
        }
    }

    private func historyTile(_ clip: AnimationClip, controller: AnimateController) -> some View {
        Button {
            controller.select(clip)
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let thumbnail = clip.thumbnail {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Color(.tertiarySystemGroupedBackground)
                    }
                }
                .frame(width: 112, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                Text(String(format: "%.0fs", clip.durationSeconds))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(5)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        controller.selectedClipID == clip.id ? Color.accentColor : .clear,
                        lineWidth: 2.5
                    )
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                controller.extendFromLastFrame(of: clip)
            } label: {
                Label("Extend from last frame", systemImage: "arrow.forward.to.line")
            }
            // Frame forking: pull the clip's last frame onto the drawing
            // canvas, fix it up, and it comes back as the START keyframe of
            // the next segment — the edit loop for building up an animation.
            Button {
                Task { @MainActor in
                    if let frame = await controller.fetchLastFrame(of: clip) {
                        coordinator.forkFrameIntoDrawing(frame, returnSlot: .start)
                    }
                }
            } label: {
                Label("Edit last frame in canvas", systemImage: "paintbrush.pointed")
            }
            Button {
                controller.restoreInputs(from: clip)
            } label: {
                Label("Reuse setup", systemImage: "slider.horizontal.3")
            }
            Button {
                if let url = controller.exportURL(for: clip) {
                    shareItem = ShareItem(url: url)
                }
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            Button(role: .destructive) {
                controller.deleteClip(clip)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

// MARK: - Motion examples panel

/// Curated motion prompts, organized by what they steer. Kept intentionally
/// physical/motion-focused — the model gets content from the keyframes; the
/// prompt describes how things MOVE.
private enum MotionExamples {
    static let sections: [(title: String, icon: String, sound: Bool, items: [String])] = [
        ("Camera", "video", false, [
            "slow zoom in",
            "slow zoom out, revealing the scene",
            "camera pans left",
            "camera pans right",
            "camera orbits around the subject",
            "camera cranes up high above",
            "handheld camera drifts gently",
            "dolly forward through the scene",
        ]),
        ("Light", "sun.max", false, [
            "golden-hour light sweeps across",
            "light shifts from day to night",
            "sunbeams break through the clouds",
            "a soft spotlight fades in",
            "neon glow pulses and flickers",
            "candlelight flickers warmly",
            "shadows stretch as the sun sets",
        ]),
        ("Atmosphere", "wind", false, [
            "a gentle breeze, everything sways",
            "rain begins to fall, puddles ripple",
            "snow drifts down softly",
            "fog rolls in low across the ground",
            "waves ripple outward",
            "leaves scatter in the wind",
            "embers and sparks rise into the air",
            "smoke curls upward slowly",
        ]),
        ("Creative", "sparkles", false, [
            "a rainstorm begins and lightning cracks through the sky",
            "the object evaporates into swirling colored sand",
            "everything melts like warm wax",
            "the scene folds itself like origami",
            "colors bleed and run like wet ink",
            "the sky turns into a swirling starry night",
            "petals burst outward in slow motion",
            "gravity reverses and everything floats upward",
            "the scene ignites into cool blue flames",
        ]),
        ("Sound", "speaker.wave.2", true, [
            "rain patters on leaves",
            "distant thunder rumbles",
            "gentle wind and birdsong",
            "waves wash in and out",
            "a crackling campfire",
            "soft dreamy music swells",
            "magical chimes sparkle",
            "low city hum, distant traffic",
        ]),
    ]
}

/// Closable panel of motion ideas docked to the preview's left edge. Narrow
/// (264pt) so it never hides much of the image; scrollable; tapping a row
/// replaces the prompt and keeps the panel open for quick experimentation.
private struct MotionExamplesPanel: View {
    /// (example, isSound) — sound rows fill the Sound box, others the Motion box.
    let onSelect: (String, Bool) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Motion ideas", systemImage: "lightbulb")
                    .font(.footnote.weight(.semibold))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(MotionExamples.sections, id: \.title) { section in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(section.title, systemImage: section.icon)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                            ForEach(section.items, id: \.self) { item in
                                Button {
                                    onSelect(item, section.sound)
                                } label: {
                                    Text(item)
                                        .font(.callout)
                                        .multilineTextAlignment(.leading)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 7)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.vertical, 10)
            }
        }
        .frame(width: 264)
        .frame(maxHeight: .infinity)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
    }
}

// MARK: - Keyframe picker

/// Sheet for filling a keyframe slot: pick from the drawing library (the
/// drawing's generated image when it has one, else the canvas) or import
/// from Photos.
private struct KeyframePickerSheet: View {
    let slot: AnimateView.KeyframeSlot
    let controller: AnimateController
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Drawing.updatedAt, order: .reverse) private var drawings: [Drawing]
    @State private var photoItem: PhotosPickerItem?

    private let columns = [
        GridItem(.adaptive(minimum: 150), spacing: 12),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(drawings.filter { !$0.isContentEmpty }) { drawing in
                        drawingTile(drawing)
                    }
                }
                .padding(16)
            }
            .navigationTitle(slot == .start ? "Start keyframe" : "End keyframe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label("Photos", systemImage: "photo.on.rectangle")
                    }
                }
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        await MainActor.run {
                            apply(image: image, drawingID: nil)
                        }
                    }
                }
            }
        }
    }

    private func drawingTile(_ drawing: Drawing) -> some View {
        let image = drawing.generatedImage ?? drawing.canvasThumbnail
        return Button {
            if let image {
                apply(image: image, drawingID: drawing.id)
            }
        } label: {
            ZStack {
                Color(.tertiarySystemGroupedBackground)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .aspectRatio(4 / 3, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func apply(image: UIImage, drawingID: UUID?) {
        switch slot {
        case .start:
            controller.startKeyframe = image
            controller.sourceDrawingID = drawingID
        case .end:
            controller.endKeyframe = image
        }
        dismiss()
    }
}

// MARK: - Looping player

/// Seamless MP4 loop via AVPlayerLooper (same approach as ResultModule's
/// LoopingVideoView, kept local because that view is module-internal).
private struct AnimateLoopingPlayerView: UIViewRepresentable {
    let url: URL
    var isMuted: Bool = false

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.configure(url: url)
        view.setMuted(isMuted)
        return view
    }

    func updateUIView(_ uiView: PlayerView, context: Context) {
        uiView.configure(url: url)
        uiView.setMuted(isMuted)
    }

    final class PlayerView: UIView {
        private var player: AVQueuePlayer?
        private var looper: AVPlayerLooper?
        private var currentURL: URL?
        private var muted = false

        override static var layerClass: AnyClass { AVPlayerLayer.self }
        private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

        func configure(url: URL) {
            guard url != currentURL else { return }
            currentURL = url
            let item = AVPlayerItem(url: url)
            let player = AVQueuePlayer()
            player.isMuted = muted
            looper = AVPlayerLooper(player: player, templateItem: item)
            self.player = player
            playerLayer.player = player
            playerLayer.videoGravity = .resizeAspect
            player.play()
            // Gray-preview diagnostics: watching plain-file playback here too
            // tells us whether a wedge episode is app-wide or specific to the
            // replay's composition path.
            VideoDiag.watch(
                player: player,
                context: "animate_clip",
                layerReady: { [weak self] in self?.playerLayer.isReadyForDisplay ?? true },
                isSuperseded: { [weak self] in
                    guard let self else { return true }
                    return self.currentURL != url
                }
            )
        }

        func setMuted(_ value: Bool) {
            muted = value
            player?.isMuted = value
        }

        override func removeFromSuperview() {
            player?.pause()
            super.removeFromSuperview()
        }
    }
}
