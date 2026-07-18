# Kiki — iPad Sketch-to-Image App

iPad-native drawing app. User sketches on left pane, AI-generated image appears on right pane via real-time FLUX.2-klein streaming.
- **Target:** iPadOS 17+, landscape only (v1)
- **Current Phase:** Phase 1 — Prototype

## Quick Commands

### iOS
```bash
# Build
xcodebuild -scheme Kiki -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' build
# Test all
xcodebuild -scheme Kiki -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' test
# Test single module
swift test --package-path ios/Packages/CanvasModule
# Lint & format
swiftlint --path ios/
swiftformat ios/
```

### Backend
```bash
cd backend && npm install          # Install deps
cd backend && npm run dev          # Dev server
cd backend && npm run build        # Build
cd backend && npm test             # Run tests
cd backend && npm run lint         # Lint
cd backend && npm run deploy       # Deploy to Railway (railway up + Sentry deploy markers)
```

## Architecture Decisions (Decided — Do Not Propose Alternatives)

**iOS:** SwiftUI for UI. **Metal for drawing** (CAMetalLayer + CADisplayLink, instanced stamp-based brush engine — see Canvas Engine below). Swift Concurrency (actors, async/await) — no Combine. URLSession for networking — no third-party HTTP libs. SwiftData for persistence. 3 local Swift packages via SPM. AppCoordinator (@Observable) injected via environment.

**Backend:** TypeScript + Fastify — no Express. Railway for hosting. The backend is a JWT-authenticated WebSocket relay (`routes/stream.ts`): it forwards canvas JPEGs to the image provider and streams generated frames back. Two providers, selected by `IMAGE_PROVIDER`: our own image servers on Lambda Cloud H100s and hosted **fal** — production runs **`auto`** (H100 pool with fal fallback, see Generation below); `fal` / `lambda` force a single provider (dev/test toggles). There is no pod orchestration and no Redis — the RunPod system (per-session GPU pods, session registry, reapers, cost monitor) was removed 2026-07-17 (`documents/decisions.md`); relays live and die with the WS connection, and Postgres holds all durable state. See `documents/references/provider-config.md` for the full ops picture.

**Accounts & billing (Postgres):** A managed **Postgres** (Railway addon → required `DATABASE_URL`) is the durable system-of-record for **user accounts** (`users`: `user_id`, `apple_sub` UNIQUE, `email`, `is_test_account`, `subscription_status`, `subscription_expires_at`) and the **per-user monthly fal-spend cap** ledger (`monthly_usage`). Raw `pg` + idempotent `schema.sql` + `migrate.ts` at boot, in `backend/src/postgres/` (mirrors `analytics/`). Sign in with Apple → JWT upserts the `users` row (`routes/auth.ts`); the old Redis user hash is retired. **Cap:** unsubscribed users get `FREE_TIER_FAL_USD` (=$10) of fal drawing spend per UTC month — test accounts + active subscribers exempt; hard mid-session stop, metered PG-direct (`backend/src/modules/falBudget/`, enforced in `routes/stream.ts`). The Apple **subscription purchase flow (StoreKit 2) is built** (Stage 3): one auto-renewable product `com.don.Kiki.pro.monthly` (~$4/mo, monthly, no trial). iOS `SubscriptionManager` purchases + posts the verified `Transaction.jwsRepresentation` to JWT-authed `POST /v1/subscription/verify`; a public `POST /v1/app-store/notify` webhook (App Store Server Notifications V2) handles renew/cancel/refund/expire. Both verify the Apple JWS with the official `@apple/app-store-server-library` (no P8 key — verification needs only the committed Apple Root CA; no required new env vars, though `APPLE_APP_APPLE_ID` must be set before *production* StoreKit verification works — sandbox/TestFlight works without it). State is **derived from the transaction** (`active` iff not revoked && `expiresDate > now`), persisted on `users` (`original_transaction_id` binds the sub to a user; `subscription_last_signed_ms` is a monotonic ordering guard for out-of-order/duplicate webhooks), and the cap exemption now also requires `subscription_expires_at > now()` so a missed webhook self-heals. Code: `backend/src/modules/appstore/`, `backend/src/routes/{subscription,appStoreNotify}.ts`, iOS `App/SubscriptionManager.swift` + `Views/PaywallView.swift`. Still Donald-side before it's live: create the App Store Connect product + set the V2 notification URL to the webhook (both Sandbox + Production). See `documents/decisions.md` (2026-06-06).

**Generation (live img2img):** the production image path (2026-07-18) is **our own FLUX.2-klein-9B-KV servers on a Lambda Cloud H100 pool**, selected by **`IMAGE_PROVIDER=auto`** on Railway: sessions relay to the least-loaded pool instance when one is assignable, else serve fal — and auto-resolved sessions **degrade to fal mid-session** if their instance dies (frames keep flowing; explicit `?imageProvider=lambda|fal` test-account overrides never silently switch, preserving A/B purity). Pool manager: `backend/src/modules/lambda/devPool.ts` — `kiki-serve-*` instances (adopted across redeploys by name prefix + HMAC token), least-loaded stream assignment, 60s tick = pinned-TLS health probes (3 strikes → terminate + replace; relays mark instances suspect on connect failure so assignment skips them immediately), pressure autoscale (`LAMBDA_POOL_TARGET_STREAMS`=4 per instance, `LAMBDA_POOL_MIN`..`MAX`), 30-min idle scale-down. Serving stack per instance: 4-step 9B-KV reference-conditioning + torch.compile (~590 ms/frame, ~5 fully-served ⅓-fps drawers/GPU); boot.sh + venv + weights live on the per-region NFS filesystem (`kiki-image-<region>`); **NFS inductor/triton cache makes restarts/scale-ups ready in ~90 s** (only the first-ever boot per region pays the ~6-min compile). **TLS**: instances serve wss with a shared self-signed cert (`$FS/kiki/tls/`, local copy `~/.kiki/lambda-tls/`); backend pins it via `LAMBDA_TLS_CA_B64`. **Metering**: $0.001/lambda-frame into the same `monthly_usage` ledger as fal (unified free tier). Lifecycle telemetry: `lambda_pool_events` (Postgres → Insights Launch tab) + `stream.provider_session` events. The kiki systemd unit is transient — `systemctl stop` deletes it; relaunch with `systemd-run --unit=kiki ... bash $FS/kiki/boot.sh`. us-south-2 H100 capacity flaps minute-scale; the pool's 15s launch-retry loop is normal operation. Full findings + measurements: `documents/plans/lambda-image-provider.md`.

**fal fallback path:** **fal.ai hosted `fal-ai/flux-2/klein/realtime`**, selected per-session by auto mode when the pool has nothing assignable (or globally via `IMAGE_PROVIDER=fal`). The backend relays each canvas JPEG to fal over a per-session realtime WebSocket (msgpack, server-side `Authorization: Key $FAL_KEY` — no secret on the client) and streams generated frames back. ~1.5s to first frame (no pod cold start), ~250ms/frame at 3 steps, ~2 FPS. fal's conditioning is its img2img feedback loop (`output_feedback_strength`/`schedule_mu`), NOT our reference-mode VAE-concat — tune those params for look. Code: `backend/src/modules/fal/falImageRelay.ts` (implements `ImageRelay`) + the fal branch in `routes/stream.ts`. fal emits no `queueEmpty`, so the relay synthesizes a `frame_meta{queueEmpty}` before each frame — kept so the future idle-state video trigger (archived, see below) can key off it unchanged. **Billing = time a warm runner is ATTACHED to your open connection** (~$0.00194/s). The **cold spin-up / enqueue wait is NOT billed** (no runner attached yet); an idle-open *warm* socket **IS** billed. This model reconciles both verification datasets: 2026-06-06 controlled runs (30.4 s open / 1 frame → $0.060 — warm-idle bills) and 2026-07-14 dashboard readback (7,526 s open of which ~6,700 s cold-wait → $1.46 ≈ the ~830 s warm-attached remainder). So the lazy-connect + `FAL_IDLE_CLOSE_MS` levers still matter (they cut warm-idle time), and `falBudget`'s open-seconds metering is approximately right for warm drawing sessions (slight overcount during cold waits only). Two cost levers in `falImageRelay.ts`: **lazy-connect** (no socket until the first stroke → opening a drawing without drawing is $0) and **`FAL_IDLE_CLOSE_MS`** (Railway env, set to `2000`; close the WS N ms after the last frame, reopen on the next stroke, so idle bills ~N s instead of ~30 s — `0` disables). fal force-closes idle sockets after ~30 s; the relay reconnects lazily. Full billing notes in `documents/references/provider-config.md`. **Keep-warm (2026-07-13; runs under `auto` too since 2026-07-18 — a cold fal pool means minutes of dropped frames exactly when the H100 pool degrades sessions onto it):** fal's marketplace pool scales to zero (warmth lapses <15 min idle; cold spin-up ~1.7–3.5 min during which fal *silently drops* all inputs and clean-closes the WS ~30 s in — NOT settings-dependent, measured). `backend/src/modules/fal/falWarmer.ts` pings the endpoint every **2 min** (tiny 1-step frame; ~$1/day-ish, cheap under compute billing) so first strokes hit a warm pool. The 2-min cadence is a measured boundary, not a guess (binary-searched 2026-07-14): warmth holds at ≤120 s gaps (0% cold, n=61) and collapses at 150 s (60% cold) / 240 s (79% cold). Don't raise the interval above 120 s — the cost difference between cadences is negligible (cold waits aren't billed); the UX difference is total. Runtime dial lives in the `admin_config.fal_warmer` Postgres row — edited live from **Kiki Insights → Ops** (enabled / interval / daily off-window, default off 2–8 am America/Los_Angeles); env `FAL_WARMER_*` only seeds the row. Ping history in `fal_warmer_pings` (Insights Ops page + Sentry `event:fal.warm_ping`).

**Lambda image path (dev, in progress):** `IMAGE_PROVIDER=lambda` (or the per-session `?imageProvider=lambda` override, test accounts only) relays to our own image server (`model-servers/image/server.py`, FLUX.2-klein BF16 — H100 is Hopper, no NVFP4) on a Lambda Cloud H100: either a static `LAMBDA_IMAGE_URL` instance or the single-instance dev pool (`backend/src/modules/lambda/devPool.ts`, 30-min idle reap, redeploy re-adoption). Auth via `KIKI_WS_TOKEN` (HMAC of instance id). See `documents/plans/lambda-image-provider.md`.

**Video idle-state animation (archived, planned to return on Lambda):** the LTX-2.3 idle-state animation ran on RunPod H100 pods and was removed with the RunPod system. The serving code (pipeline, WS server, protocol test client), design docs, perf investigations, and Lambda porting notes live in `archive/video-ltx/` — read its README before reviving. iOS's video render path (`VideoEvent` parsing, `ResultState.videoStreaming/.videoLooping`, `LoopingVideoView`) is intact and inert until a backend sends `video_*` messages again. License gotcha for the revival: LTX-2 Community License Agreement (NOT Apache-2.0, restricts commercial use ≥$10M revenue) — verify before App Store submission.

## Navigation & Persistence

State-based navigation via `AppCoordinator.currentScreen` (`.gallery` | `.drawing`). No NavigationStack.

- **Gallery view** (`GalleryView`) — root screen when drawings exist. 2-column grid of tiles. Uses `@Query` to observe SwiftData directly.
- **Drawing view** (`DrawingView`) — canvas + result pane. Gallery button top-left navigates back. Stream starts automatically when entering a drawing. Three layouts (Settings → Display, `AppCoordinator.drawingLayout`): **overlay** (the default — generated image locked opaque exactly on top of the canvas, pan/zoom/rotate together; fresh strokes flash on a visual-only surface above it and clear on each returned generation frame; spec: `documents/plans/completed/overlay-mode.md`), **split-screen** (fixed result pane on the left half), and **fullscreen** (the canvas drawing surface fills the available pane below the toolbar; the result floats as the panel below).
- **Fullscreen result panel** (`FloatingResultPanel`) — in fullscreen the generated image floats over the canvas, sized to the image (rounded corners + drop shadow, no chrome/buttons), always visible. It's **visual-only** (`allowsHitTesting(false)`): a single finger / pencil draws straight through it onto the canvas, while **two fingers** over it move + pinch-scale it (aspect-locked, no rotation) — driven by the canvas container's `externalTransformRegionProvider` / `onExternalTransform` hooks, the only view that sees both fingers while single touches still draw. Transform state lives in `panelOffset` / `panelScale`. While drawing, a soft **transparency hole** (`AppCoordinator.panelHole`, rendered as a `.mask` in `FloatingResultPanel`, fed by the container's `onContactPointChanged` and mapped via `PanelLayout.rect`) follows the pencil so the canvas shows through; it fades closed on lift. The whole effect reads `panelHole` only in the `FloatingResultPanel` leaf, so 120 Hz contact updates never re-render `DrawingView` or touch the Metal draw path.
- **Style picker** — `PromptStyle` (`PromptStyle.allStyles`) defines available styles; the selected style's `promptSuffix` is appended to the user's prompt client-side before sending to backend. The picker is a `.fullScreenCover` (hides the status bar to match `RootView`). Each style has a static `1024²` thumbnail at `Assets.xcassets/style_thumbnail_<id>.imageset`, with a procedural `StyleThumbnailSpec` fallback in `StylePickerView.swift`. **Adding a style** (3 edits + 1 command): (1) add the `PromptStyle` to the front of `allStyles` in `PromptStyle.swift`; (2) generate its thumbnail with `backend/scripts/gen-style-thumbnail.sh <id> "<promptSuffix>"` — renders the shared courier reference scene via fal.ai **`fal-ai/flux-2`** text-to-image (note: klein is img2img-only on fal, so thumbnails use full flux-2; needs `FAL_KEY` in `backend/.env.local`); (3) add a matching `StyleThumbnailSpec` case. No `.pbxproj` edit needed (asset catalog is folder-referenced).
- **Drawing model** (`Drawing.swift`) — SwiftData `@Model` with `@Attribute(.externalStorage)` for image blobs (drawing data, background image, generated image, canvas thumbnail). Settings: prompt, style ID.
- **Auto-save** — debounced 1s on stroke/prompt changes.
- **Pending-state pattern** — `CanvasViewModel.setPendingState()` queues canvas data before navigation; `attach()` applies it when the canvas view is created.
- **Empty drawing cleanup** — `navigateToGallery()` deletes drawings with no content.

## Canvas Engine (Metal)

The drawing canvas uses a custom Metal-based rendering engine (`MetalCanvasView` + `CanvasRenderer`) for GPU-accelerated painting at 120 Hz. Key architecture:

- **Display**: `CAMetalLayer` (double-buffered, `.bgra8Unorm_srgb`) driven by `CADisplayLink`. Only renders when dirty.
- **Canvas texture**: `.shared` storage — GPU and CPU access the same unified memory. No CPU↔GPU copies per frame.
- **Document resolution (fixed, decoupled from view size)**: layer/scratch textures are allocated **once** at a fixed `2048²` (`MetalCanvasView.documentSide`) by `CanvasRenderer.configureDocument` — they are **NOT** sized to the view. `layoutSubviews` updates only `CAMetalLayer.drawableSize` (which tracks the view); the compositor scales the fixed document onto the drawable. So a view/layout change (style-picker `fullScreenCover`, fullscreen↔split-screen toggle, rotation) only restrides the *display* — the document is **never reallocated or resampled**, so resolution is preserved and strokes are never wiped on resize. Touch→texture mapping funnels through `canvasScale` = document÷view ratio (refreshed every `layoutSubviews`), so on-screen brush size is view-size-invariant. **Do not** re-tie the texture size to `bounds` — that's the exact regression fixed on 2026-06-06 (the style picker's transient bounds wobble was wiping/blurring the canvas; see commit `4f99ea7`).
- **Brush rendering**: instanced stamp quads. Touch points → arc-length resampled positions → `StampInstance` buffer → single instanced draw call per frame. Adaptive spacing (stamp gap = 30% of pressure-modulated width) keeps strokes dense at all pressures.
- **Eraser**: stamps applied directly to canvas texture with destination-out blend, per touchesMoved. Undo snapshot taken at touchesBegan.
- **Active stroke**: rendered into a scratch texture (ephemeral), composited onto the canvas each frame. Flattened into the canvas texture on touchesEnded.
- **Undo**: full-texture CPU snapshots (`texture.getBytes()` → `Data`), depth 30. Restore via `texture.replace()`.
- **Stream capture**: reads canvas texture via `persistentImageSnapshot` (CGImage from `.shared` texture). **Never** uses `drawHierarchy` — that forces a synchronous GPU drain.
- **Color correctness (read this before touching any color/snapshot/eyedropper code)**: the `.bgra8Unorm_srgb` textures make Metal's hardware own the sRGB↔linear gamma at every texture boundary, so **texture-side ops speak linear (linearSRGB / `s2l` brush color), image/file outputs speak sRGB**. The "obvious" choice is wrong on both sides and we shipped bugs both ways (washed-out exports, eyedropper drift, save→reopen → black). Never read a `CAMetalLayer` pixel via `CALayer.render`/`drawHierarchy` (captures nothing); prefer explicit `CGColorSpace(name: CGColorSpace.sRGB)!` over `CGColorSpaceCreateDeviceRGB()` for intent (but note: DeviceRGB is a verified sRGB pass-through in iOS bitmap contexts — the old "it's Display P3" claim was false; see the module doc's 2026-07-13 correction). Full mental model + the exact wrong-intuition list: `ios/Packages/CanvasModule/CLAUDE.md` → "Color pipeline — the one correct mental model".
- **Lasso**: Phase 2 (path drawing works, selection extraction not yet implemented).
- **Smudge**: not yet implemented on Metal (reverted from a CPU attempt that hit <1 fps). Will be a ping-pong texture fragment-shader pass. See `documents/plans/metal-canvas-rewrite.md`.

### Performance invariants
- `applyEraserStamps` creates a temporary `MTLBuffer` per batch (no shared-buffer races) and commits **without** `waitUntilCompleted`.
- `flattenScratchIntoCanvas` is the only `waitUntilCompleted` on the drawing hot path — runs once per stroke end, not per frame.
- `clearTexture` uses `waitUntilCompleted` but only runs at initial document allocation (`configureDocument`) — not interactive, and not on resize (the document is fixed-size and never resized; see Document resolution above).

## Module Dependencies

```
CanvasModule       → (none)
NetworkModule      → (none)
ResultModule       → (none)
AppCoordinator     → all 3 modules + SwiftData
```
Data flows one direction: Canvas → Network → Result. Modules communicate through AppCoordinator. No circular dependencies. No module imports the main app target.

## Critical Constraints (NEVER Violate)

1. **Canvas responsiveness is sacred.** Metal rendering NEVER depends on network/generation state. Target <8ms stroke latency at 120 Hz. NEVER call `drawHierarchy(afterScreenUpdates: true)` or `waitUntilCompleted()` on the main-thread hot path — use `texture.getBytes()` on `.shared` storage for CPU reads, and async command buffer commits for GPU writes.
2. **Never clear the right pane.** Always keep last successful image visible. Never show blank after first successful generation.
3. **No secrets on client.** Provider API keys and URLs backend only. Client NEVER calls inference providers directly.
4. **Code is private.** The GitHub repo is private. Never make Docker images, packages, or artifacts public — our source code is embedded in them. Never recommend exposing code publicly as a workaround for infrastructure problems.
5. **Content safety before external testing.** Prompt input filter must be operational before any external TestFlight build. (NSFW *output* filtering is intentionally not required — dropped 2026-06-06.)
6. **Privacy: drawings are captured server-side (owner decision 2026-07-15, supersedes the old "sketches are ephemeral" rule).** The backend mirrors a throttled sample of each session's sketch + generated JPEGs to Kiki Insights for admin replay (Insights → Gallery). Bounds: ≥1 s between stored frames per kind, ≤600 frames/kind/stream, deleted after `CAPTURE_RETENTION_DAYS` (14). Kill switch: `SESSION_CAPTURE_ENABLED=false` on Railway. **Before any external TestFlight/App Store build: privacy policy + App Store data-collection disclosure MUST state that drawings are stored server-side.** Code: `backend/src/modules/insights/frameCapture.ts` → `analytics` `/ingest/capture`.
7. **App Store compliance.** Must include: first-launch AI disclosure consent (guideline 5.1.2(i)), age gate (1.2.1(a)), content filtering, "Report this image" button.

## Cost during dev/testing

We do not optimize for cost during development, profiling, or one-off experiments. **Anything under $100 is negligible.** Don't waste time saving a few dollars by tearing down test pods between iterations, picking cheaper GPU SKUs that complicate debugging, or skipping a clean re-test because "we already paid for the data once." User-revenue scale dominates GPU spend by orders of magnitude; iteration speed is the real constraint. This applies to Lambda test instances, Railway redeploys, repeat profiler captures, and any other dev-time GPU/infra spend.

## Debugging rigor (applies to every diagnosis)

When diagnosing a failure, separate observations from inferences. Do not collapse multiple distinct failure modes into a single tidy narrative — cleaner stories mislead remediation.

- **List each failure mode on its own line with the specific evidence that supports it.** If two failures happened at different pipeline stages, they are almost certainly distinct root causes even if both produce the same user-visible symptom.
- **A step that completed had whatever precondition it needed, by definition.** A pod that was successfully created had capacity. A container that started had a working image. Don't count later failures as evidence against earlier conditions that were already proven.
- **Label claim strength.** Distinguish between "proven by event X", "consistent with but not proven", and "inferred from behavior Y". Weak and strong evidence must not share the same confident voice.
- **A punchy one-liner root cause is a warning sign.** If you catch yourself writing "everything is X" or "the whole thing is broken because Y", reopen the evidence — don't close it. The clean story usually dropped something that matters.

## Explaining how something works

When asked how a system behaves, trace the flow from its entrypoint (WS handler, request route, scheduled tick) — don't start from the data model or type definitions and reason outward. Half the answers live in how the entrypoint invokes shared code, and that's invisible from the schema.

- **Schema, types, and comments describe intent; call sites describe behavior.** When they disagree, the call site wins. Quoting a doc comment without reading the implementation it describes is the most common way to confidently mislead. The comment may have been right when written and gone stale since.
- **Cite the source of each claim.** "Per the comment at file:line, …" vs. "the code at file:line does …" — if a reader can't tell which one a claim came from, they can't weight it. Pattern-matching on field names (e.g. inferring meaning from `podUrl` containing `wss://`) is the same hazard: state that you're inferring from naming, not verifying.
- **Hedge inferred claims; don't share voice with verified ones.** "Haven't verified," "based on the architecture doc," "consistent with but not proven." A summary table or bulleted answer that mixes verified and inferred claims in the same authoritative voice is worse than a shorter answer that only includes the verified parts.
- **For "how does X work" questions specifically:** read the entrypoint first, then follow it through one happy path end-to-end before generalizing or summarizing. Jumping to a summary table from the data model alone is the failure mode.

## Observability

**Three Sentry projects, one per platform:**

| Project | Covers | DSN env var | Notes |
|---|---|---|---|
| `kiki-ios` | Swift app | (in iOS app config) | iOS app errors + crashes |
| `kiki-backend` | Node/Fastify on Railway | `SENTRY_DSN` (Railway) | Backend errors + structured logs |
| `kiki-pod` | Python image server (`model-servers/`) | `SENTRY_DSN_POD` | **Currently dormant**: RunPod-era pods set it via BOOT_ENV; Lambda instances don't set it yet. Wire it into `boot.sh` if Lambda serving needs Sentry. |

The Python image server logs via stdlib `logging` → `LoggingIntegration` ships `INFO+` lines into Sentry's Logs product. Init lives in `model-servers/shared/sentry_init.py`, called from `image/server.py`. `pod_kind` and `pod_id` are attached **two ways**: as scope tags (covers errors/spans/transactions) and as log attributes via a `before_send_log` hook (covers the Logs product — scope tags don't propagate there, found out the hard way). No-op when `SENTRY_DSN_POD` is unset (local runs stay quiet).

**Server logging conventions** — apply to every new `logger.X(...)` call in `model-servers/`:

- **Use f-string body + `extra={...}`. Never positional `%s`/`%d`.** Positional args become opaque `message.parameter.0..N` indices in Sentry's Logs UI. f-strings render the body literally so the expanded view is human-readable, and `extra` keys auto-promote to top-level queryable attributes (Sentry SDK's `_extra_from_record` does this — same path used by `code.*` / `thread.*` / `process.*`).
- **Use `extra={}` for fields you'd want to filter or aggregate on** (e.g. `gen_ms`, `frames`, `client_id`). Skip it for throwaway diagnostics — no value in indexing every transient string.
- **Don't manually set `pod_kind` / `pod_id`.** The `before_send_log` hook in `sentry_init.py` injects them on every log. If you want pod-scoped attributes added globally, extend that hook — don't sprinkle them per-call.
- **Avoid stdlib LogRecord-reserved keys in `extra={}`** — `name`, `msg`, `args`, `levelname`, `levelno`, `pathname`, `filename`, `module`, `exc_info`, `exc_text`, `stack_info`, `lineno`, `funcName`, `created`, `msecs`, `relativeCreated`, `thread`, `threadName`, `processName`, `process`, `message`. Python's logging raises `KeyError` on collision. Prefix domain keys (`pod_id`, `client_id`, `gen_ms`) and you'll be fine.
- **`sentry_sdk.set_tag()` ≠ log attribute.** Tags propagate to errors/spans only, not to the Logs product. To attach something to log entries, use `before_send_log` (global) or `extra={}` (per-call).
- **Reading logs back via Sentry MCP `search_events`:** the MCP's query agent silently drops unrecognized attribute names from `fields=[...]` — if a field is missing from the response but visible in the Sentry UI, the data is fine, the MCP agent just didn't surface it. Cross-check in `donki.sentry.io` → Logs before chasing it as a code bug.

**Cross-stack `phase` attribute** — for filtering "what user-journey moment is this log from" across iOS / backend / pods. Single shared vocabulary; the layer dimension is filterable independently via Sentry project + `pod_kind`.

| `phase` value | When |
|---|---|
| `preparing` | Fresh launch through "able to draw". Backend: WS-open slow path (budget gate + relay wiring). iOS: loading state. Image server: model load + warmup. User-language phrasing — the app is preparing to be ready. |
| `drawing` | Active drawing, image stream live. Backend: WS relay. iOS: stroke handling + preview. Image server: per-frame generation. |
| `animating` | (Reserved for the video idle-state revival — see `archive/video-ltx/`.) iOS: video preview. |
| `reconnecting` | Recovering from a mid-session disconnect. iOS detects via "warming after first frame already received." Backend wraps `handleUpstreamClose` recovery in `withPhase('reconnecting')`. |
| `session_ending` | Session winding down. |
| `deploying` | Ops-side: a deploy is in flight. Set by `backend/scripts/deploy.ts` via `backend/scripts/lib/deploy-sentry.ts`. Distinct from user-journey phases (deploys can run during active sessions). Lets you query "everything that happened during the last deploy". Requires `SENTRY_DSN` in `.env.local` for local CLI runs to ship to Sentry; no-op without it. |

**Mechanisms (all three layers shipped):**

- **Image server (Python):** `model-servers/shared/sentry_init.py` exports a `phase()` context manager backed by `contextvars.ContextVar`. Set with `with sentry_init.phase("drawing"):` — propagates through `asyncio.create_task` and `asyncio.to_thread` into all logs emitted within (Python 3.9+ copies contextvars snapshot into spawned tasks/threads).
- **Backend (TS):** `backend/src/modules/observability/phase.ts` exports `withPhase('preparing', async () => {...})` backed by Node `AsyncLocalStorage`. Wrap the section of code; `beforeSendLog` in `index.ts` reads the active phase at log-emit time and injects as `phase` attribute.
- **iOS:** `ios/Kiki/App/Phase.swift` exports `Phase.set(.drawing)` (imperative, thread-safe via `OSAllocatedUnfairLock`). Imperative rather than `@TaskLocal` because URLSession WS delegate callbacks fire off-Task and TaskLocal doesn't propagate. Single-active-stream guarantees the global is unambiguous. The `Log.X` facade reads `Phase.current` at emit time.

**Don't introduce server-internal sub-phases** as separate top-level values — fold them into the user-journey phase and rely on existing structured fields (`gen_ms` etc.) and `code.function.name` (auto-attached) for sub-stage discrimination. If a real cross-stack debugging need requires finer granularity, add a `subphase` attribute alongside.

**Cross-stack user identity propagation.** Every layer tags every log + error event with `user_id`:

- **iOS:** `SentrySDK.setUser(User(userId:))` after sign-in (cleared on sign-out). `Log.X` facade injects `stream_id` from `StreamContext`.
- **Backend:** `Sentry.setUser({id})` per-request (via `fastifyIntegration` async-context isolation) in `auth/index.ts` preHandler. `pinoIntegration` auto-captures Pino logs; `beforeSendLog` in `index.ts` normalizes camelCase → snake_case (`userId`→`user_id`, etc.) so cross-stack queries don't fragment. **Filter by `user_id:<X>` (the snake_case attribute), not `user.id:<X>` (the Sentry user model)** — the attribute is set deterministically per-log; the user model relies on ambient scope and can be wrong.
- **Image server:** `model-servers/shared/sentry_init.py` reads `KIKI_USER_ID` + `KIKI_STREAM_ID` from env at startup (RunPod-era; a shared Lambda instance serves multiple users, so per-user env attribution doesn't apply there — attribute by timestamp + backend logs instead).

**Don't `Sentry.setUser` in long-lived contexts** (WS handlers, background timers, schedulers). The SDK's scope cleanup is aligned with HTTP request lifecycles via `fastifyIntegration`, not with WS-connection lifetimes. Setting user from a WS handler leaks onto the global scope and contaminates background-process logs with the most recent user's id — distorting `user_id:<X>` queries with rows that have nothing to do with that user. Backend WS-handler user attribution comes from the `userId` Pino structured field on every log call (see `routes/stream.ts` — every `request.log.X({userId, ...}, ...)` already carries it). For errors that need user attribution from inside the WS scope, pass `{ user: { id: userId } }` explicitly to `Sentry.captureException`.

**Background-process callbacks must run via `inBackgroundScope('<name>', fn)`** from `backend/src/modules/observability/scope.ts`. Wraps the callback in `Sentry.withIsolationScope`, clears `setUser`, and tags `background_task: <name>`. Used by the fal warmer and the Lambda dev-pool reaper. New periodic timers should use the same helper so their logs (a) never inherit ambient user state and (b) are filterable as a class via `background_task:<name>`.

**Server-side `preparing` heartbeat.** While the image server is in `phase: preparing` (model load), `preparing_heartbeat.py` emits a `preparing heartbeat:` log line every 15s with `host_rss_gib`, `cuda_alloc_gib`, `cuda_reserved_gib`, `elapsed_sec`. The trajectory tells "host RSS climbed then went silent" vs. "memory was fine, something else killed it." Threading-based (not asyncio) because pipeline.load() blocks the event loop for 60-90s.

**Cross-project search:** Sentry's UI page-filter handles "all projects" or any subset. The cross-stack `user_id`/`phase` attributes make project boundary effectively just permissions/alerts/quotas — not a data silo.

**Trace-id-based correlation across WebSocket** is *not* yet wired (Sentry auto-propagates `trace_id` for HTTP but not WS). v1 relies on `user_id` + timestamp for joining iOS → backend, which covers the common debugging queries. Add WS trace-id propagation as a follow-up if the user_id-based query proves insufficient.

**Clock skew across layers.** When stitching cross-stack logs by timestamp, ±1s drift between iOS / backend (Railway) is normal — all NTP-synced but not the same source. Don't over-interpret sub-second ordering.

**Errors UI vs Logs UI.** Sentry has two separate datasets, both filterable by `user_id`. The Errors UI shows `captureException` / `captureMessage` events with stack traces and grouping. The Logs UI shows lifecycle log lines (Pino on backend, `SentrySDK.logger.X` on iOS). When debugging, check both — different perspectives on the same incident.

**Division of concerns:** Sentry owns errors and stdout/stderr logs exclusively; Kiki Insights owns product analytics events, per-user timelines, and session replay. (PostHog was removed 2026-07-17 — Insights had fully replaced it.)

**Kiki Insights** (`analytics/`) is our own **internal per-user analytics dashboard** — a standalone Railway service (`kiki-insights` in the `kiki-backend` project) at `https://kiki-insights-production.up.railway.app` (admin-password gated; password in the `ADMIN_PASSWORD` Railway var). It answers "what has *this one user* done over their whole time in Kiki" — login/session timeline, full event stream, and a drawings gallery — which the aggregate-first Sentry views don't. It **shares the backend's Postgres**: reads the backend-owned `users` (identity, `is_test_account`, subscription) + `monthly_usage` (fal spend) and owns its own `events`/`sessions`/`drawings` tables; blobs live on a Railway volume behind a swappable `BlobStore`. It does **not** replace Sentry — Sentry keeps errors/logs; Insights is the product-analytics store. Events arrive from both layers: the backend sends every `modules/analytics/index.ts` event (`modules/insights/client.ts`, gated by `INSIGHTS_URL`+`INSIGHTS_INGEST_KEY`), and iOS sends every `Analytics.track` (`InsightsSink.swift`, gated by `insightsURL` in `AppCoordinator.init`). Deploy with `cd analytics && railway up --ci --service kiki-insights --path-as-root .` (the `--path-as-root .` is **required** — without it `railway up` uploads the repo root and the build fails). Full details + schema + setup: `analytics/README.md`.

**Querying logs programmatically** (e.g. for analysis without copy-pasting): use the Sentry MCP server (`https://mcp.sentry.dev/mcp`) — registered at user scope on Donald's Claude Code config, exposes `search_events` / `search_issues` / `search_spans`. Avoids the manual "paste logs into chat" workflow.

### How to debug a user session

Standard query patterns. Sentry → Logs UI, "all projects" page filter unless noted.

| Question | Query |
|---|---|
| Full timeline of one user's session (iOS + backend) | `user_id:<X>` sorted ascending by time |
| What happened during the user's preparing phase | `user_id:<X> phase:preparing` |
| One specific WS connection | `conn_id:<X>`; the whole user attempt across reconnects is `stream_id:<X>` |
| Relay wiring failures for one user | `event:wire_relay_session_failed user_id:<X>` (one row with the per-attempt array) |
| Logs we forgot to wrap in a phase | `user_id:<X> !has:phase` |
| Verify deploy correlates with errors | `phase:deploying` (on Logs UI) + Errors UI filtered by time around that deploy |

When a user reports an issue, default workflow:
1. Get `user_id` from Kiki Insights or in-app context.
2. `user_id:<X>` Logs query, sorted by time → see what happened.
3. If phase-specific (e.g. "stuck on loading" → `phase:preparing`).
4. Cross-check Errors UI for stack traces around that timeframe.
5. For session content ("my drawing looked wrong"), replay the session in Insights → Gallery.

### Reading wire_relay failures

When the backend can't open a WS to the image provider (`wire_relay_failed`), the symptom alone is consistent with several causes. `wire_relay_session_failed` (rich forensic, one row per failed session) fires when every attempt failed; `wire_relay_failed` per-attempt logs carry phase timings (`dnsMs`/`tcpMs`/`tlsMs`/`upgradeMs`), error codes (`errno`), and HTTP response details (`httpStatus`, `httpHeaders`, truncated `httpBodySample`).

Reading the patterns — *interpretation guide, not proof of cause*:

| If queries show… | …a candidate explanation that fits |
|---|---|
| `kind:unexpected_response` + `httpStatus:5xx` + `httpHeaders.server:uvicorn` + traceback in `httpBodySample` | Lambda image-server route handler issue (FastAPI threw, etc.) |
| `errno:ECONNREFUSED` on the lambda path | Instance up but server not listening (boot.sh failed / venv broken) |
| `errno:ENOTFOUND` / `EAI_AGAIN`, or `phaseTimings.dnsMs > 1000` | DNS / Railway-side network |
| `phaseTimings.tlsMs > 5000` | TLS handshake slow (rare; congested network) |
| fal-path failures | Check fal status + `fal_connections` history (Insights → Ops) — cold-pool spin-up silently drops inputs (see Keep-warm above) |

**Event-name family:** `wire_relay_failed`, `wire_relay_open`, `wire_relay_session_failed`. Search by `event:<name>` in Sentry Logs UI.

## Key References

| When | Read |
|------|------|
| Content safety / App Store compliance | `documents/references/content-safety.md` |
| Provider architecture (fal + Lambda), billing, costs | `documents/references/provider-config.md` |
| Archived LTX video system + Lambda porting notes | `archive/video-ltx/README.md` |
| UX test cases (must-pass manual checklist)              | `documents/test-cases.md` |
| Metal canvas architecture plan (layers, smudge, etc.) | `documents/plans/metal-canvas-rewrite.md` |
| Pro-brush roadmap (flow/opacity → stabilization → stamps → wet/oil paint; Procreate parity) | `documents/plans/pro-brush-roadmap.md` |
| FLUX.2-klein capability notebook (potential features, not committed) | `documents/ideas/flux-klein-capabilities.md` |
| Lambda Cloud H100 image provider (IMAGE_PROVIDER=lambda) — architecture, scripts, cold-start plan | `documents/plans/lambda-image-provider.md` + `backend/scripts/lambda/README.md` |
| Internal per-user analytics dashboard (Kiki Insights) — setup, schema, ingest contract, deploy | `analytics/README.md` |
| **iOS TestFlight release** — always run `ios/scripts/testflight-release.sh` (one command: build+upload+distribute). Signing, API key, gotchas | `documents/references/testflight-release.md` |
| Implementation decisions log | `documents/decisions.md` |
| Removed features (RunPod orchestration, PostHog, ComfyUI, StreamDiffusion) | `documents/removed-features.md` |
| Product requirements | `PRD.md` |
| System architecture | `TECHNICAL_ARCHITECTURE.md` |

## Deploy Process

**Backend:** `cd backend && npm run deploy` — wraps `railway up` with Sentry `phase:deploying` log markers. Any change under `backend/src/**` needs it. Plain `railway up` (from `backend/`) works too, just without the deploy markers.

**Kiki Insights:** `cd analytics && railway up --ci --service kiki-insights --path-as-root .` (the `--path-as-root .` is required).

**Lambda image server** (`model-servers/` changes): re-run `backend/scripts/lambda/setup-lambda.ts` for the region (rsyncs code + rebuilds venv if needed); a running instance keeps its in-memory copy until restarted. See `backend/scripts/lambda/README.md`.

**iOS:** rebuild + reinstall (simulator or device); TestFlight via `ios/scripts/testflight-release.sh`.

## Completion reporting

At the end of any task that touches code, config, or infra, finish with a short status block so Donald knows whether he can test next or whether something else is gating him. Skip the block on read-only/research turns where nothing changed.

Format:

- **Code state:** one of — `uncommitted` (working tree only) / `committed on main (local)` / `pushed to origin/main`.
- **Ready to test?** `yes` or `no`. If `no`, list every step that remains before Donald can exercise the change. Common gates in this repo:
  - **Backend (Railway) redeploy** — `cd backend && npm run deploy`. Required for any change under `backend/src/**`.
  - **Lambda image-server sync** — for `model-servers/` changes: re-run `setup-lambda.ts` and restart the instance (a running instance keeps the old code in memory).
  - **iOS rebuild + reinstall** — Swift changes don't hot-reload. Note simulator vs. device. Flag if SwiftData schema changed (state reset needed).
  - **Env var / secret / third-party config** — name it explicitly (e.g. "set `FAL_KEY` in Railway", "accept Gemma terms on HF").
- **What to test:** one or two sentences on the golden path that verifies the change.

If a step is something Donald has to run himself (e.g. App Store Connect change, anything requiring his credentials/2FA), say so explicitly rather than leaving it ambiguous.

## Git Conventions

- When Donald asks to commit and push work from the current conversation, commit directly on `main` and push `origin main`. Do not create a feature branch or PR unless explicitly requested. Stage only changes that belong to the current conversation/task; leave unrelated dirty worktree changes untouched.
- **Branches:** `feature/module-short-desc`, `fix/module-short-desc`, `chore/desc`
- **Commits:** Conventional format — `feat(canvas): add snapshot export`, `fix(scheduler): discard stale preview`
- One logical change per commit. Prefix with module name when scoped.
