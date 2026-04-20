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
```

## Architecture Decisions (Decided — Do Not Propose Alternatives)

**iOS:** SwiftUI for UI. **Metal for drawing** (CAMetalLayer + CADisplayLink, instanced stamp-based brush engine — see Canvas Engine below). Swift Concurrency (actors, async/await) — no Combine. URLSession for networking — no third-party HTTP libs. SwiftData for persistence. 3 local Swift packages via SPM. AppCoordinator (@Observable) injected via environment.

**Backend:** TypeScript + Fastify — no Express. Railway for hosting. Backend is both a WebSocket relay AND a pod orchestrator: it provisions a dedicated RTX 5090 pod per session (JWT-authenticated), relays frames to that pod, and terminates pods idle > 10 min. Redis-backed session registry (survives deploys), semaphore caps concurrent cold starts. See `documents/references/provider-config.md` for the full ops picture.

**Generation:** FLUX.2-klein-4B on RunPod RTX 5090 spot, with BFL's NVFP4 transformer checkpoint loaded on top of the BF16 pipeline. Real-time img2img streaming over WebSocket. Canvas captured at ~2 FPS, sent as JPEG, generated images returned ~1 FPS. Reference-mode only: the sketch is VAE-encoded and concatenated with generation latents as conditioning tokens. Server uses frame dropping (single-slot buffer) to prevent queue buildup. ~110–150s cold start (slim GHCR image + pre-populated network volumes).

## Navigation & Persistence

State-based navigation via `AppCoordinator.currentScreen` (`.gallery` | `.drawing`). No NavigationStack.

- **Gallery view** (`GalleryView`) — root screen when drawings exist. 2-column grid of tiles. Uses `@Query` to observe SwiftData directly.
- **Drawing view** (`DrawingView`) — canvas + result split pane. Gallery button top-left navigates back. Stream starts automatically when entering a drawing.
- **Style picker** — `PromptStyle` model defines available styles. Selected style's `promptSuffix` is appended to the user's prompt client-side before sending to backend.
- **Drawing model** (`Drawing.swift`) — SwiftData `@Model` with `@Attribute(.externalStorage)` for image blobs (drawing data, background image, generated image, canvas thumbnail). Settings: prompt, style ID.
- **Auto-save** — debounced 1s on stroke/prompt changes.
- **Pending-state pattern** — `CanvasViewModel.setPendingState()` queues canvas data before navigation; `attach()` applies it when the canvas view is created.
- **Empty drawing cleanup** — `navigateToGallery()` deletes drawings with no content.

## Canvas Engine (Metal)

The drawing canvas uses a custom Metal-based rendering engine (`MetalCanvasView` + `CanvasRenderer`) for GPU-accelerated painting at 120 Hz. Key architecture:

- **Display**: `CAMetalLayer` (double-buffered, `.bgra8Unorm_srgb`) driven by `CADisplayLink`. Only renders when dirty.
- **Canvas texture**: `.shared` storage — GPU and CPU access the same unified memory. No CPU↔GPU copies per frame.
- **Brush rendering**: instanced stamp quads. Touch points → arc-length resampled positions → `StampInstance` buffer → single instanced draw call per frame. Adaptive spacing (stamp gap = 30% of pressure-modulated width) keeps strokes dense at all pressures.
- **Eraser**: stamps applied directly to canvas texture with destination-out blend, per touchesMoved. Undo snapshot taken at touchesBegan.
- **Active stroke**: rendered into a scratch texture (ephemeral), composited onto the canvas each frame. Flattened into the canvas texture on touchesEnded.
- **Undo**: full-texture CPU snapshots (`texture.getBytes()` → `Data`), depth 30. Restore via `texture.replace()`.
- **Stream capture**: reads canvas texture via `persistentImageSnapshot` (CGImage from `.shared` texture). **Never** uses `drawHierarchy` — that forces a synchronous GPU drain.
- **Lasso**: Phase 2 (path drawing works, selection extraction not yet implemented).
- **Smudge**: not yet implemented on Metal (reverted from a CPU attempt that hit <1 fps). Will be a ping-pong texture fragment-shader pass. See `documents/plans/metal-canvas-rewrite.md`.

### Performance invariants
- `applyEraserStamps` creates a temporary `MTLBuffer` per batch (no shared-buffer races) and commits **without** `waitUntilCompleted`.
- `flattenScratchIntoCanvas` is the only `waitUntilCompleted` on the drawing hot path — runs once per stroke end, not per frame.
- `clearTexture` uses `waitUntilCompleted` but only runs during canvas resize (not interactive).

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
5. **Content safety before external testing.** NSFW output filter + prompt input filter must be operational before any external TestFlight build.
6. **Privacy by design.** Sketch data is ephemeral on server — deleted after generation response.
7. **App Store compliance.** Must include: first-launch AI disclosure consent (guideline 5.1.2(i)), age gate (1.2.1(a)), content filtering, "Report this image" button.

## Key References

| When | Read |
|------|------|
| Content safety / App Store compliance | `documents/references/content-safety.md` |
| RunPod deploy, provider ops, network volumes | `documents/references/provider-config.md` |
| Pod lifecycle edge cases (MUST-handle matrix)          | `backend/src/modules/orchestrator/orchestrator.ts` (file header) |
| Two-pod video architecture (LTXV split) plan + context | `documents/plans/two-pod-video-architecture.md` + GitHub #25 |
| Cost monitoring, Discord alerts, pod lifecycle threads | `backend/src/modules/orchestrator/costMonitor.ts` |
| Scale-to-100-users roadmap + workstream status | `documents/plans/scale-to-100-users.md` |
| Metal canvas architecture plan (layers, smudge, etc.) | `documents/plans/metal-canvas-rewrite.md` |
| Implementation decisions log | `documents/decisions.md` |
| Removed features (ComfyUI, StreamDiffusion) | `documents/removed-features.md` |
| Product requirements | `PRD.md` |
| System architecture | `TECHNICAL_ARCHITECTURE.md` |

## Deploy Process

**Backend (Fastify on Railway):** `cd backend && railway up`. No git push.

**Pod Docker image (flux-klein-server on RunPod):** Push to `main` touching `flux-klein-server/**` → GitHub Actions builds and pushes to `ghcr.io/donpinkus/kiki-flux-klein:latest`. `FLUX_IMAGE` on Railway is set to `:latest`, so new pods automatically pull the latest image — no Railway update needed. SHA-pinned tags (`:sha-<commit>`) are also pushed for rollback: `railway variables set FLUX_IMAGE=ghcr.io/donpinkus/kiki-flux-klein:sha-<commit>`. **Warning:** the SHA in the tag is GitHub's merge commit SHA (`github.sha`), NOT the local git commit SHA — check the Actions run log for the exact tag.

Existing running pods are unaffected — only newly provisioned pods pick up the new image. To force a user onto the new image, terminate their pod and let the orchestrator reprovision.

## Git Conventions

- **Branches:** `feature/module-short-desc`, `fix/module-short-desc`, `chore/desc`
- **Commits:** Conventional format — `feat(canvas): add snapshot export`, `fix(scheduler): discard stale preview`
- One logical change per commit. Prefix with module name when scoped.
