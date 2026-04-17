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

**iOS:** SwiftUI for UI. PencilKit for drawing. Swift Concurrency (actors, async/await) — no Combine except PencilKit delegate bridging. URLSession for networking — no third-party HTTP libs. SwiftData for persistence. Core Image + vImage for image processing. 3 local Swift packages via SPM. AppCoordinator (@Observable) injected via environment.

**Backend:** TypeScript + Fastify — no Express. Railway for hosting. Backend is both a WebSocket relay AND a pod orchestrator: it provisions a dedicated RTX 5090 spot pod per session (`session=<uuid>` query param), relays frames to that pod, and terminates pods idle > 10 min. In-memory session registry, semaphore caps concurrent cold starts. See `documents/references/provider-config.md` for the full ops picture.

**Generation:** FLUX.2-klein-4B on RunPod RTX 5090 spot, with BFL's NVFP4 transformer checkpoint loaded on top of the BF16 pipeline. Real-time img2img streaming over WebSocket. Canvas captured at ~2 FPS, sent as JPEG, generated images returned ~1 FPS. Reference-mode only: the sketch is VAE-encoded and concatenated with generation latents as conditioning tokens. Server uses frame dropping (single-slot buffer) to prevent queue buildup. ~3–5 min cold start per fresh session.

## Navigation & Persistence

State-based navigation via `AppCoordinator.currentScreen` (`.gallery` | `.drawing`). No NavigationStack.

- **Gallery view** (`GalleryView`) — root screen when drawings exist. 2-column grid of tiles. Uses `@Query` to observe SwiftData directly.
- **Drawing view** (`DrawingView`) — canvas + result split pane. Gallery button top-left navigates back. Stream starts automatically when entering a drawing.
- **Style picker** — `PromptStyle` model defines available styles. Selected style's `promptSuffix` is appended to the user's prompt client-side before sending to backend.
- **Drawing model** (`Drawing.swift`) — SwiftData `@Model` with `@Attribute(.externalStorage)` for image blobs (drawing data, background image, generated image, canvas thumbnail). Settings: prompt, style ID.
- **Auto-save** — debounced 1s on stroke/prompt changes.
- **Pending-state pattern** — `CanvasViewModel.setPendingState()` queues canvas data before navigation; `attach()` applies it before the PKCanvasView delegate is set.
- **Empty drawing cleanup** — `navigateToGallery()` deletes drawings with no content.

## Module Dependencies

```
CanvasModule       → (none)
NetworkModule      → (none)
ResultModule       → (none)
AppCoordinator     → all 3 modules + SwiftData
```
Data flows one direction: Canvas → Network → Result. Modules communicate through AppCoordinator. No circular dependencies. No module imports the main app target.

## Critical Constraints (NEVER Violate)

1. **Canvas responsiveness is sacred.** PencilKit rendering NEVER depends on network/generation state. Target <16ms stroke latency.
2. **Never clear the right pane.** Always keep last successful image visible. Never show blank after first successful generation.
3. **No secrets on client.** Provider API keys and URLs backend only. Client NEVER calls inference providers directly.
4. **Content safety before external testing.** NSFW output filter + prompt input filter must be operational before any external TestFlight build.
5. **Privacy by design.** Sketch data is ephemeral on server — deleted after generation response.
6. **App Store compliance.** Must include: first-launch AI disclosure consent (guideline 5.1.2(i)), age gate (1.2.1(a)), content filtering, "Report this image" button.

## Key References

| When | Read |
|------|------|
| Content safety / App Store compliance | `documents/references/content-safety.md` |
| RunPod deploy, provider ops, network volumes | `documents/references/provider-config.md` |
| Cost monitoring, Discord alerts, pod lifecycle threads | `backend/src/modules/orchestrator/costMonitor.ts` |
| Scale-to-100-users roadmap + workstream status | `documents/plans/scale-to-100-users.md` |
| Implementation decisions log | `documents/decisions.md` |
| Removed features (ComfyUI, StreamDiffusion) | `documents/removed-features.md` |
| Product requirements | `PRD.md` |
| System architecture | `TECHNICAL_ARCHITECTURE.md` |

## Git Conventions

- **Branches:** `feature/module-short-desc`, `fix/module-short-desc`, `chore/desc`
- **Commits:** Conventional format — `feat(canvas): add snapshot export`, `fix(scheduler): discard stale preview`
- One logical change per commit. Prefix with module name when scoped.
