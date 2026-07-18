# Deep technical audit — open findings (2026-07-18)

Four deep correctness audits ran against the system's most complex components,
each checked against its own documented invariants: the Metal canvas engine,
the fal relay billing state machine, the iOS stream lifecycle, and the Python
image server. **Everything safely fixable without device testing was fixed on
the audit branch** (see `git log` — display-link leak, fal billing races,
image-server token compare, StreamRelay closedByUs guard). This file records
what remains: findings that need a device, a runtime repro, or a product
decision. Ordered by recommended priority.

Verification status of each claim is labeled: **proven** (code path traced,
cited), **suspected** (mechanism real, trigger frequency unknown).

---

## P1 — iOS stream lifecycle (needs runtime repro before + after any fix)

Source files: `StreamSession.swift`, `StreamWebSocketClient.swift`,
`AppCoordinator.swift` (stream sections).

1. **Silently-dead connection stays `.ready` (suspected, most likely to be a
   real user complaint).** There is no ping/keepalive or receive-idle deadline
   once a session is `.ready`, and capture-loop `sendFrame` failures are
   swallowed (logged to Sentry, no reconnect). A post-ready half-open socket —
   the same proxy half-close the *handshake* explicitly guards against with
   its 10s first-message timeout — leaves the UI on "ready" while nothing
   regenerates. Fix direction: receive-side idle deadline or app-level ping
   while `.ready`; escalate repeated send failures to `attemptReconnect`.

2. **Overlapping StreamSessions via check-then-act (proven race, seconds-wide
   window).** `startStream()` guards `streamSession != nil`, but the
   assignment happens after an `await authService.currentAccessToken()`
   (network-refresh wide). Two entries (e.g. a scheduled retry + a foreground
   trigger) both pass the nil-check → two live sessions, two streamIds,
   phase/readiness clobbered — undermining the single-active-stream guarantee
   the Phase design depends on. Fix: synchronous `isStarting` flag.

3. **Reconnect reuses a frozen JWT (proven).** The Bearer header is baked into
   the `URLRequest` at session start; `runReconnect` never re-fetches. An
   expired token mid-session → 5 futile retries → "Unable to connect. Please
   restart the app." (wrong UX; should re-auth). Fix: re-fetch a token per
   reconnect attempt.

4. **`connectAndRunOnce` misses a post-await stop check (proven).** After
   `client.connect()` resumes, receive/capture loops start even if `stop()`
   ran meanwhile — an orphaned session keeps invoking coordinator callbacks.
   Fix: `guard !isStopped, !Task.isCancelled` between the awaits and loop
   creation. Mechanical, but validate under a stress test.

5. Smaller: `Phase` can stick at `.reconnecting` if a reconnected session
   reaches ready but no frame returns; `streamFrameCount` isn't reset on
   drawing open (first `.warming` of a new drawing misclassifies as
   `reconnecting`); server error codes other than `free_limit_reached` all
   collapse to a terminal `.failed` banner (`lambda_not_ready` — a transient —
   is treated as permanent; `invalid_token` gets no re-auth); WS close codes
   (1008/1011/1013/1001) are never inspected; initial-connect
   `ServerRejectedError` waits one backoff before showing the paywall; a
   `.failed` session makes `startStream()` a silent no-op (any future Retry
   button must route through `resumeStream()`).

Verified good, for the record: constraint #2 (never blank the pane) holds on
every path traced; AuthService single-flight refresh is correct; no data races
in the actor/MainActor-isolated state.

## P2 — Metal canvas engine (needs device testing / design decisions)

Source: `CanvasRenderer.swift`, `MetalCanvasView.swift`. The audit verified
the big documented invariants genuinely hold: no `waitUntilCompleted` on any
per-frame/per-touch path, no banned capture APIs, fixed-2048² document never
re-tied to bounds, color pipeline correct at every checked boundary, undo
snapshots fire on every pixel-mutating tool. Remaining findings:

1. **Layer structural ops are not undoable; layer delete is destructive
   (proven; design decision).** `addLayer` / `deleteLayer` / `moveLayer` /
   `toggleLayerVisibility` push no undo entry, and `deleteLayer` also purges
   the deleted layer's undo history — its pixels are unrecoverable. Decide:
   make structural ops undoable, or at minimum confirm-dialog the delete.

2. **Undo memory is bounded by count, not bytes (proven; design decision).**
   30 entries × 16 MB/layer snapshot; a compound clearAll/import entry
   snapshots every layer (up to 256 MB/entry). Heavy multi-layer sessions can
   hold hundreds of MB → jetsam risk. Recommend a byte-budget trim in
   `trimUndoAndClearRedo`.

3. **Shared `stampBuffer` overwritten per frame with no in-flight fence
   (suspected; device testing).** Frame N+1's CPU writes can race frame N's
   in-flight GPU reads (window is sub-ms vs 8 ms frames — may never manifest;
   would show as transient stroke flicker). Standard fix: small buffer ring +
   semaphore.

4. **Cancel/restore vs async GPU writes (suspected; device testing).**
   `touchesCancelled` → `texture.replace()` on the CPU isn't ordered against
   a still-in-flight async eraser/smudge pass to the same texture.

5. Smaller: main-thread `waitUntilCompleted` in the snapshot paths runs at
   capture cadence (~2 fps) — fine per docs, worth a device trace;
   `exportStrokeData` encodes via `UIImage.pngData()` where the module doc
   mandates `CIContext.pngRepresentation` (spot-check semi-transparent
   pixels).

## P3 — fal relay residuals (low, monitor after the billing fixes deploy)

1. **FIFO result-matching assumes warm fal is strictly 1:1 (suspected).** If
   fal is itself latest-wins under load, `frame_meta.requestId` can echo a
   stale id and mis-pair style previews. Watch `fal.inflight_abandoned` (new
   log from this audit's fix) — frequent hits would indicate the 1:1
   assumption is wrong.
2. **Cold-open overcount is now documented, not fixed**: metering counts
   open-socket time during cold spin-ups that fal doesn't bill (conservative,
   ~cents). Gating span-start on first received frame would trade this for
   undercounting warm-idle — deliberately not done.
3. No reconnect backoff: post-timeout retries can loop tightly while the user
   keeps drawing (bounded by the 15s connect timeout; converges).

## P4 — Python image server residuals

1. **No watchdog on a hung generation (suspected, worst-case severe).** A
   stuck CUDA kernel holds the pipeline lock forever — every client on the
   instance stalls; the pool's health probe (`/health` still answers) may not
   catch it. Consider a generation deadline that marks the instance unhealthy.
2. **`KIKI_WS_TOKEN` travels in the URL query** → appears in uvicorn access
   logs (and anything shipping those). Proper fix is a header
   (`Authorization`), coordinated across `devPool.wsUrlFor`, `sketchify`,
   `boot.sh` and the server — do as one change.
3. Pre-auth log lines (`pod.ws.upgrade_attempt`, bad-token warns) ship to
   Sentry per unauthenticated hit on a public IP — log-cost abuse surface.
4. `frame_meta`→binary is two sends; a disconnect between them leaves a
   dangling meta (impact limited: the socket is dead, relay sees close).

---

Cross-cutting recommendations that came out of all four audits:

- The backend test suite (5 tests) covers none of the billing/reconnect logic
  this audit found bugs in. The fal relay's accounting (span accumulation,
  idle-close, in-flight tracking) is highly unit-testable with a mocked ws —
  highest-value place to add tests.
- The `dev` naming residue (`devPool.ts`, `LAMBDA_DEV_POOL_ENABLED`,
  `/v1/dev/lambda/*`) and `FREE_TIER_FAL_USD` (now provider-agnostic) both
  need env-var coordination with Railway to rename — batch them with the next
  breaking config change.
- Internal H100 price quotes disagree ($2.49 / $3.29 / $4.29 per hour across
  three files); the $0.001/frame metering rate was derived from the highest.
  Reconcile against the Lambda pricing page before any margin math.
