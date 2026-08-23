import AVFoundation
import os
import Sentry
import UIKit

/// Long-running diagnostics for the "gray video preview" device-state bug
/// (2026-08-22: replay previews rendered gray in BOTH the page and the sheet
/// until the iPad was rebooted — same binary played fine afterwards, so the
/// failure lives in device/daemon state, not app code). This module stays in
/// the app for weeks so the next natural occurrence is fully captured in
/// Sentry instead of being a gray mystery.
///
/// What it captures, and which suspect each signal discriminates:
///
/// - **Watchdog verdict** on every player attach (replay page, replay sheet,
///   Animate clips): did the AVPlayerLayer ever get frames?
/// - **Frames decoded vs frames composited** (lazily-attached
///   `AVPlayerItemVideoOutput`): pixel buffers vended but layer never ready →
///   CoreAnimation/render-server problem; nothing vended → decode-side.
/// - **Independent codec probe** (tiny H.264 encode via AVAssetWriter +
///   decode via AVAssetReader, run only on failure): fails → hardware
///   codec/daemon exhaustion (leaked VTDecompressionSessions, wedged
///   mediaserverd); succeeds while the player starves → playback-pipeline
///   wedge specifically.
/// - **Media services lost/reset notifications**: the system telling us the
///   media daemon died/restarted. A reset right after gray episodes is the
///   smoking gun for the mediaserverd theory.
/// - **Device uptime** in every event: correlates wedge onset with time
///   since reboot, and proves which reboots cleared it.
/// - **Memory + thermal snapshot**: pressure at failure time (the jetsam
///   theory).
/// - **Cross-launch episode counter** (UserDefaults): distinguishes "app
///   relaunch fixes it" (process-level) from "only reboot fixes it"
///   (device-level) without anyone having to remember to test.
///
/// Query in Sentry Logs: `event:video.playback_no_display` (failures),
/// `event:video.playback_ok` (baselines), `event:video.media_services_lost`.
enum VideoDiag {

    private static let appStart = Date()

    // MARK: - Global listeners (install once at app start)

    /// Media-services death/restart tracking. `mediaServicesWereLost` fires
    /// when the media daemon dies under us; `...WereReset` when it comes
    /// back. Either near a gray episode is strong evidence for the wedged-
    /// daemon theory.
    static func installGlobalListeners() {
        // Per-run churn counters (UserDefaults for thread-safety; reset each
        // launch). The decoder-exhaustion theory predicts episodes AFTER
        // heavy churn — these make that correlation readable off one event.
        for key in ["videoDiag.run.watchCount", "videoDiag.run.exportCount",
                    "videoDiag.run.backgroundCount"] {
            UserDefaults.standard.set(0, forKey: key)
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { _ in
            bump(counter: "videoDiag.run.backgroundCount")
        }
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereLostNotification,
            object: nil, queue: .main
        ) { _ in
            bump(counter: "videoDiag.mediaLostCount")
            let attrs = systemSnapshot(merging: ["event": "video.media_services_lost"])
            Log.warn("video.media_services_lost", attributes: attrs)
            SentrySDK.capture(message: "video.media_services_lost") { scope in
                for (k, v) in attrs { scope.setExtra(value: v, key: k) }
            }
        }
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil, queue: .main
        ) { _ in
            bump(counter: "videoDiag.mediaResetCount")
            Log.warn("video.media_services_reset", attributes:
                systemSnapshot(merging: ["event": "video.media_services_reset"]))
        }
    }

    // MARK: - Watchdog

    /// Watch one player attach and log a verdict. Call right after
    /// `player.play()`. `layerReady` reads AVPlayerLayer.isReadyForDisplay —
    /// the definitive "the screen is actually getting frames" signal.
    /// `isSuperseded` lets the caller invalidate the watch when the player
    /// is swapped (replay recomposes) or reconfigured (Animate loops).
    @MainActor
    static func watch(
        player: AVPlayer,
        context: String,
        layerReady: @escaping () -> Bool,
        isSuperseded: @escaping () -> Bool
    ) {
        let started = Date()
        bump(counter: "videoDiag.run.watchCount")
        Log.info("video.playback_watch", attributes: systemSnapshot(merging: [
            "event": "video.playback_watch",
            "context": context,
        ]))

        Task { @MainActor in
            var readyAtMs: Int?
            // Poll up to 15s; healthy playback exits within ~1s.
            for _ in 0..<75 {
                try? await Task.sleep(for: .milliseconds(200))
                if isSuperseded() { return }
                let item = player.currentItem
                if readyAtMs == nil, item?.status == .readyToPlay {
                    readyAtMs = elapsedMs(since: started)
                }
                if layerReady() {
                    Log.info("video.playback_ok", attributes: [
                        "event": "video.playback_ok",
                        "context": context,
                        "time_to_ready_ms": readyAtMs ?? -1,
                        "time_to_display_ms": elapsedMs(since: started),
                    ])
                    return
                }
                if item?.status == .failed {
                    // The hosting view surfaces failed items to the user;
                    // here we only need the telemetry side.
                    reportNoDisplay(
                        player: player, context: context, verdict: "item_failed",
                        started: started, readyAtMs: readyAtMs, framesVended: nil, probe: nil
                    )
                    return
                }
                // 4s with a ready item and no frames on screen = the gray
                // rectangle. Collect the deep evidence.
                if let readyAtMs, elapsedMs(since: started) - readyAtMs > 4000 {
                    break
                }
                // Never-ready items fall through to the deep pass at 15s.
            }
            if isSuperseded() || layerReady() { return }
            await deepDiagnose(
                player: player, context: context,
                started: started, readyAtMs: readyAtMs, layerReady: layerReady
            )
        }
    }

    /// The gray state is on screen right now — capture everything that
    /// separates the candidate causes, then keep watching for late recovery.
    @MainActor
    private static func deepDiagnose(
        player: AVPlayer,
        context: String,
        started: Date,
        readyAtMs: Int?,
        layerReady: @escaping () -> Bool
    ) async {
        guard let item = player.currentItem else {
            reportNoDisplay(player: player, context: context, verdict: "no_item",
                            started: started, readyAtMs: readyAtMs, framesVended: nil, probe: nil)
            return
        }

        // Discriminator 1: are frames being DECODED at all? Attach a video
        // output now (lazily — attaching one up front could perturb the
        // healthy path) and see whether pixel buffers get vended.
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        item.add(output)
        try? await Task.sleep(for: .milliseconds(700))
        let vendTime = item.currentTime()
        let framesVended = output.hasNewPixelBuffer(forItemTime: vendTime)
            && output.copyPixelBuffer(forItemTime: vendTime, itemTimeForDisplay: nil) != nil
        item.remove(output)

        // Discriminator 2: does the hardware codec path work AT ALL right
        // now, independent of AVPlayer? (Encode+decode a tiny clip.)
        let probe = await codecProbe()

        let verdict: String
        if item.status != .readyToPlay {
            verdict = "preroll_stuck"
        } else if framesVended {
            // Decode fine, screen empty → compositor / render server.
            verdict = "decoded_not_composited"
        } else if (probe["probe_decode_ok"] as? Bool) == false {
            verdict = "decoder_unavailable"
        } else {
            verdict = "player_pipeline_wedged"
        }

        reportNoDisplay(player: player, context: context, verdict: verdict,
                        started: started, readyAtMs: readyAtMs,
                        framesVended: framesVended, probe: probe)

        // Late-recovery check: did it self-heal without a reboot? (Tells us
        // whether the wedge is transient.)
        try? await Task.sleep(for: .seconds(10))
        Log.info("video.playback_no_display_followup", attributes: [
            "event": "video.playback_no_display_followup",
            "context": context,
            "recovered_late": layerReady(),
            "still_current": item === player.currentItem,
        ])
    }

    @MainActor
    private static func reportNoDisplay(
        player: AVPlayer,
        context: String,
        verdict: String,
        started: Date,
        readyAtMs: Int?,
        framesVended: Bool?,
        probe: [String: Any]?
    ) {
        bump(counter: "videoDiag.episodeCount")
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "videoDiag.lastEpisodeAt")

        var attrs = systemSnapshot(merging: [
            "event": "video.playback_no_display",
            "context": context,
            "verdict": verdict,
            "watch_elapsed_ms": elapsedMs(since: started),
            "time_to_ready_ms": readyAtMs ?? -1,
            "player_rate": player.rate,
            "time_control": player.timeControlStatus.rawValue,
            "waiting_reason": player.reasonForWaitingToPlay?.rawValue ?? "none",
            "external_playback": player.isExternalPlaybackActive,
        ])
        if let framesVended { attrs["frames_vended"] = framesVended }
        if let item = player.currentItem {
            attrs["item_status"] = item.status.rawValue
            attrs["item_error"] = item.error.map(String.init(describing:)) ?? "none"
            attrs["current_time_s"] = item.currentTime().seconds
            attrs["duration_s"] = item.duration.seconds
            attrs["presentation_w"] = Double(item.presentationSize.width)
            attrs["presentation_h"] = Double(item.presentationSize.height)
            attrs["likely_to_keep_up"] = item.isPlaybackLikelyToKeepUp
            attrs["buffer_empty"] = item.isPlaybackBufferEmpty
            // First few error-log entries carry the daemon-side error codes.
            if let events = item.errorLog()?.events.prefix(3) {
                attrs["error_log"] = events.map {
                    "\($0.errorDomain)#\($0.errorStatusCode) \($0.errorComment ?? "")"
                }.joined(separator: " | ")
            }
        }
        if let probe {
            attrs.merge(probe) { a, _ in a }
        }

        Log.error("video.playback_no_display", attributes: attrs)
        SentrySDK.capture(message: "video.playback_no_display") { scope in
            scope.setTag(value: verdict, key: "video_verdict")
            scope.setTag(value: context, key: "video_context")
            for (k, v) in attrs { scope.setExtra(value: v, key: k) }
        }
        Analytics.track(.videoPlaybackNoDisplay, properties: [
            "context": context,
            "verdict": verdict,
            "episode_count": UserDefaults.standard.integer(forKey: "videoDiag.episodeCount"),
        ])
    }

    /// Call once per replay MP4 export (encoder churn is a suspect input to
    /// the wedge — leaked VT sessions from killed exports).
    static func noteVideoExport() {
        bump(counter: "videoDiag.run.exportCount")
    }

    // MARK: - Independent codec probe

    /// Exercise the hardware H.264 encoder AND decoder outside AVPlayer:
    /// write a 6-frame 240² clip with AVAssetWriter, read it back with
    /// AVAssetReader. Both paths go through the same media daemons and VT
    /// sessions the player needs, so "probe fails" vs "probe fine but player
    /// starves" splits the daemon-exhaustion theory from the playback-
    /// pipeline theory. Runs only when a failure is already being reported.
    private static func codecProbe() async -> [String: Any] {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kiki-videodiag-probe.mp4")
        try? FileManager.default.removeItem(at: url)
        var result: [String: Any] = [:]
        let side = 240

        // Encode.
        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: side,
                AVVideoHeightKey: side,
            ])
            input.expectsMediaDataInRealTime = false
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: side,
                    kCVPixelBufferHeightKey as String: side,
                ]
            )
            writer.add(input)
            writer.startWriting()
            writer.startSession(atSourceTime: .zero)
            for frame in 0..<6 {
                var pb: CVPixelBuffer?
                CVPixelBufferCreate(kCFAllocatorDefault, side, side, kCVPixelFormatType_32BGRA, nil, &pb)
                guard let buffer = pb else { break }
                CVPixelBufferLockBaseAddress(buffer, [])
                memset(CVPixelBufferGetBaseAddress(buffer), frame % 2 == 0 ? 0x20 : 0xD0,
                       CVPixelBufferGetDataSize(buffer))
                CVPixelBufferUnlockBaseAddress(buffer, [])
                while !input.isReadyForMoreMediaData {
                    try await Task.sleep(nanoseconds: 2_000_000)
                }
                adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 12))
            }
            input.markAsFinished()
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                writer.finishWriting { c.resume() }
            }
            result["probe_encode_ok"] = writer.status == .completed
            if writer.status != .completed {
                result["probe_encode_error"] = writer.error.map(String.init(describing:)) ?? "status \(writer.status.rawValue)"
            }
        } catch {
            result["probe_encode_ok"] = false
            result["probe_encode_error"] = String(describing: error)
        }

        // Decode what we just wrote (skip if the encode never produced a file).
        do {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                result["probe_decode_ok"] = false
                result["probe_decode_error"] = "no video track in probe clip"
                return result
            }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ])
            reader.add(output)
            reader.startReading()
            var frames = 0
            while let sample = output.copyNextSampleBuffer() {
                if CMSampleBufferGetImageBuffer(sample) != nil { frames += 1 }
            }
            result["probe_decode_ok"] = reader.status == .completed && frames > 0
            result["probe_decoded_frames"] = frames
            if reader.status == .failed {
                result["probe_decode_error"] = reader.error.map(String.init(describing:)) ?? "unknown"
            }
        } catch {
            result["probe_decode_ok"] = false
            result["probe_decode_error"] = String(describing: error)
        }
        try? FileManager.default.removeItem(at: url)
        return result
    }

    // MARK: - System snapshot

    /// Ambient device state attached to every diagnostic event. Uptime is the
    /// reboot correlator; memory + thermal cover the pressure theory; the
    /// persistent counters make cross-launch/cross-reboot history visible in
    /// any single event.
    private static func systemSnapshot(merging extra: [String: Any]) -> [String: Any] {
        let defaults = UserDefaults.standard
        var attrs: [String: Any] = [
            "device_uptime_s": Int(ProcessInfo.processInfo.systemUptime),
            "app_uptime_s": Int(Date().timeIntervalSince(appStart)),
            "thermal_state": thermalName(ProcessInfo.processInfo.thermalState),
            "low_power_mode": ProcessInfo.processInfo.isLowPowerModeEnabled,
            "available_memory_mb": Int(os_proc_available_memory() / 1_048_576),
            "media_lost_count": defaults.integer(forKey: "videoDiag.mediaLostCount"),
            "media_reset_count": defaults.integer(forKey: "videoDiag.mediaResetCount"),
            "episode_count": defaults.integer(forKey: "videoDiag.episodeCount"),
            "run_watch_count": defaults.integer(forKey: "videoDiag.run.watchCount"),
            "run_export_count": defaults.integer(forKey: "videoDiag.run.exportCount"),
            "run_background_count": defaults.integer(forKey: "videoDiag.run.backgroundCount"),
        ]
        let lastEpisode = defaults.double(forKey: "videoDiag.lastEpisodeAt")
        if lastEpisode > 0 {
            attrs["last_episode_age_s"] = Int(Date().timeIntervalSince1970 - lastEpisode)
        }
        attrs.merge(extra) { _, b in b }
        return attrs
    }

    private static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private static func bump(counter key: String) {
        let defaults = UserDefaults.standard
        defaults.set(defaults.integer(forKey: key) + 1, forKey: key)
    }

    private static func elapsedMs(since date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1000)
    }
}
