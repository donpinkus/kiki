# iPad code review — 2026-07-17

> **Fix status (same day):** P1 items 1–6 fixed in `db387b2`; P2 items 7–12
> fixed in `3a9f49c` (item 13's SUSPECTED notes remain open); P3 swept in
> `efbbe56`. P4 remains open. Canvas fixes verified via BrushHarness
> (battery byte-identical; stamp-cap stress test old-FAIL/new-PASS;
> layer-stack round-trip PASS) + OfflineTests ALL PASSED.

Four-part review (app core, views, Network/Result/Export packages, CanvasModule)
following the RunPod/PostHog removal. Findings ranked by severity. Items marked
**[verified]** were re-checked by hand at the cited lines; the rest are
reviewer-reported (each labeled CONFIRMED/SUSPECTED by the reviewer that read
the path end-to-end).

## P1 — Real user-facing bugs (fix before TestFlight)

1. **[verified] Any non-2xx during token refresh wipes the Keychain and signs
   the user out.** `AuthService.swift:318-330` throws `backendRejected` for ANY
   non-2xx (a Railway redeploy 502 included), and `refresh()` (`:281-288`)
   responds to `backendRejected` with `signOut()`. Sign-out should be gated on
   401/`invalid_refresh_token` only.

2. **[verified] Concurrent token refreshes race a one-time-use refresh token →
   spurious sign-out.** `AuthService.currentAccessToken()` (`:131-146`) has no
   in-flight-refresh coalescing; actor reentrancy lets cold-launch's ~4
   near-simultaneous callers (entitlements, usage, lambda pool, stream) each
   POST the same refresh token. Backend rotates on first use, so losers get
   rejected → finding 1's `signOut()` wipes the winner's fresh tokens too.
   Fix: coalesce into a single in-flight refresh Task.

3. **[verified] Offline at stream start destroys credentials.**
   `AppCoordinator.swift:1442-1453` — the `startStream` token-fetch catch is
   unconditional: any error (plain `URLError` offline included) → "Please sign
   in again" + `signOut()`. Distinguish `AuthError.noToken`/`refreshFailed`
   (sign out) from transport errors (banner + retry).

4. **[verified] Style-preview flow is broken on fal (production) and corrupts
   the result pane + saved drawing.** The fal relay hardcodes
   `requestId: null` on every synthesized `frame_meta`
   (`backend/src/modules/fal/falImageRelay.ts:319`), but preview pairing keys
   on the echoed requestId (`StreamSession.swift:565-574`). So on fal: preview
   continuations never resolve (tiles shimmer forever — the 20s timeout also
   can't fire, `StylePreviewController.swift:63-79`, because the task group
   must await the stuck non-cancellable continuation), and every preview
   render routes to `onImageReceived` → overwrites `lastSuccessfulImage` and
   gets persisted as the drawing's generated image on next auto-save.
   Fix options: echo the client's requestId in the fal relay's synthesized
   frame_meta (backend, small), + make the iOS timeout cancel-safe.

5. **"Warming up the AI / Ready in about 90 seconds" is wrong for every
   session.** **[verified copy]** `ResultView.swift:155-164` renders on every
   fal connect: a ~1.5s warm connect flashes pod-era copy; a cold fal pool
   (2–3.5 min) promises "90 seconds" and the progress machinery
   (`:110-145,170-205`) never advances — `startedAt` is always nil now
   (backend never sends `warmingStartedAt`). Replace with honest
   "Connecting…" copy; drop the 90s bar machinery.

6. **Out-of-credit at connect never shows the paywall.** (CONFIRMED)
   Backend denies with `{type:'error', code:'free_limit_reached'}` before
   closing; `StreamWebSocketClient.connect()` (`:243-257`) drops the `code`,
   so `runReconnect` shows a generic red banner instead of the Subscribe
   affordance. The same condition mid-session shows the paywall correctly —
   the two paths should match. Fix: carry `code` through
   `ServerRejectedError` and route to `onServerError`.

## P2 — Canvas correctness (the sacred surface)

7. **[verified] Undo entries store layer indices that go stale on layer
   delete/move.** `MetalCanvasView.swift:155,2227,2245-2248` vs
   `deleteLayer`/`moveLayer` (`:2307-2316`) which never remap
   `undoSnapshots`/`redoSnapshots`. Undo after a layer delete/move restores
   onto whatever layer now holds that index — silently clobbers another
   layer's content. Fix: remap indices on delete/move (or key by stable layer
   id).

8. **`clearAll` is not undoable on multi-layer canvases.** (CONFIRMED)
   `:2322-2328` snapshots only the active layer before
   `resetToSingleLayer()` destroys all layers — other layers unrecoverable.

9. **Debug `NSLog("🔬OVL …")` left on the 120 Hz render hot path.** (CONFIRMED)
   32 sites across `MetalCanvasView.swift`/`CanvasRenderer.swift` (+1 in
   `AppCoordinator.openDrawing`, +2 in `DrawingView.body` incl.
   `Self._printChanges()`). Several synchronized log writes per display tick.
   Delete (leftover from the June overlay-freeze investigation).

10. **4096-stamp buffer cap silently truncates long strokes — including at
    flatten.** (CONFIRMED) `CanvasRenderer.swift:255-259` +
    `MetalCanvasView.swift:972-978,1158-1163`: the brush path regenerates the
    whole stroke per frame into a buffer sized for incremental stamps; a long
    dense stroke stops extending and the tail is permanently missing.
    Replay (`commitStampsToCanvas`) has no cap, so replay and live diverge.

11. **Missing end-cap dab on non-stabilized strokes.** (CONFIRMED)
    `MetalCanvasView.swift:1113-1119` only regenerates with
    `includeEndCap: true` when the stabilizer returns a non-empty tail;
    `streamline == 0` brushes always commit the cap-less preview stamps.
    Visible on wide-spacing brushes (Spray Paint).

12. **`bakeImage` pushes no undo snapshot** (`:2331-2337`) — undo after "Send
    to Canvas" skips the bake and wipes the prior operation too. (CONFIRMED)

13. Lower-confidence canvas notes (SUSPECTED, timing-dependent): shared
    `stampBuffer` CPU rewrite vs in-flight GPU read (one-frame scratch flash
    at QuickShape commit); `pushUndoSnapshot` `getBytes` without syncing the
    previous stroke's async commits; `framebufferOnly = false` on the display
    layer justified by a comment citing the banned `drawHierarchy` API.

## P3 — Stranded pod-era code (dead since the backend cleanup)

All CONFIRMED-dead; grouped for one cleanup pass. The backend now only emits
`{type:'state', state:'connecting'|'ready'}`.

- `ProvisionState.swift`: `queued/findingGpu/creatingPod/fetchingImage/
  warmingModel/failed/terminated` cases, `FailureCategory`, the
  "Replacing — " prefix, and doc comments citing deleted backend files.
- The whole idle-timeout/resume subsystem: `StreamSession.swift:709-723`,
  `ResultState.idleTimeout`, `ResultView.idleTimeoutView` ("Session Paused -
  Draw to Resume"), `AppCoordinator.handleUserActivity` auto-resume,
  `onResumeTapped` plumbing. Note the product gap it papers over: a
  server-side session end now surfaces as a bare reconnect loop, not the
  designed tap-to-resume.
- `ResultState.generating` + `GenerationPhase`/`GenerationProgress` +
  `generatingView`/`progressPanel` (~150 lines; had no producer even before
  the cleanup).
- `ServerStatus.replacementCount/failureCategory/warmingStartedAt/
  stateEnteredAt` (`StreamWebSocketClient.swift:35-41`) + the warm-progress
  `startedAt` plumbing through StreamSession/ResultState.
- Stale comments asserting deleted behavior: `AppCoordinator.swift:974-976`
  (signout "terminates the pod"), `:830-832,965-966` (90s pre-warm),
  `StreamSession.swift:319-325,698-702,764-771,804`,
  `AuthService.swift:213-214`, `ParticleField.swift:3-8`,
  `ResultView.swift` previews ("Reserving GPU…"), `KikiApp.swift:38-42`
  (Phase is lock-based now, not TaskLocal).

## P4 — Smaller items

- **Video-revival hazards** (in deliberately-kept code): `LoopingVideoView`'s
  fallback KVO likely never attaches (`ResultView.swift:708-751` reads
  `player.currentItem` before `AVPlayerLooper` enqueues copies — the
  "never clear the pane" protection is inert); `SpeedPaintReplayView.swift:
  129-136` end-of-item observer registered with `object: nil` (any player
  app-wide resets the replay); 16 MB WS `maximumMessageSize` vs base64 MP4s
  (`StreamWebSocketClient.swift:189-191`) — a >12 MB video kills the whole
  stream.
- `sendConfig`/`sendFrame` silently no-op when not connected
  (`StreamWebSocketClient.swift:291-305`) while the caller records the config
  as sent (`StreamSession.swift:334-335`) — dropped prompt/style change in a
  race window.
- `resumeStream` (paywall purchase / provider toggle) abandons the in-flight
  timelapse recorder unfinalized (`AppCoordinator.swift:1637-1644` →
  `:1480-1483`) — replay footage lost, temp MP4s leak.
- Sentry `user_id` is never set on relaunch (`AppCoordinator` init restores
  the Keychain user but only `signInWithApple` calls `SentrySDK.setUser`) —
  cross-stack `user_id:<X>` queries miss iOS for returning users.
- `BrushStudioView` `@State dyn` isn't re-seeded when a curated preset is
  applied while the panel is open — next control touch clobbers the preset.
- Brush Studio/Settings small stuff: "Reset All to Defaults" sets
  `streamCaptureFPS = 2` vs default 5; Diagnostics footer references
  SCP-from-pod; share menu renders inert "Share image" rows;
  `PaywallView` re-shows a stale `lastError` on re-open; `streamReconnect`
  analytics fires a phantom attempt on the exhaustion pass;
  `.subscriptionRestored` event defined but never tracked; capture-loop JPEG
  encode runs on the main actor every 200ms (pre-existing).
- Canvas cruft (zero callers, safe deletes): `exportStrokeData()` (also the
  only banned-API `pngData()` on canvas pixels), `pendingCanvasImage` +
  `applyPendingCanvasImage()`, `ellipsePreviewPath`,
  `LassoSelectionView.commitTransform()`, no-arg `UIImage.pixelColor()`,
  `CanvasRenderer.snapshotCanvas()/restoreCanvas(from:)`,
  `StrokeStabilizer.isPassthrough`; `wetOrderingPerStamp` A/B toggle plumbed
  through four layers; scratch-texture "memoryless" header comment is false;
  empty test dirs (`CanvasModuleTests`, `ResultModuleTests`) while root
  CLAUDE.md lists `swift test` for CanvasModule.
- Compliance reminder (self-documented): Sentry session replay ships
  `maskAllText/maskAllImages = false` at 100% sampling — revisit before any
  external build (Constraint 6 disclosure).

## Clean bills of health

PostHog: zero references anywhere in iOS. Color pipeline: all live paths
conform to the CanvasModule mental model (the one violation is inside dead
`exportStrokeData`). Document-resolution invariants respected. WS
exactly-once disconnect emission, InsightsSink queueing, KeychainStore,
SubscriptionManager entitlement derivation, DrawingVideoRecorder
checkpointing, and the dormant video wire-format all check out.
