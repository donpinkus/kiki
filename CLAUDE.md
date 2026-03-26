# Kiki — iPad Sketch-to-Image App

iPad-native drawing app. User sketches on left pane, AI-generated image appears on right pane. PencilKit + ComfyUI (Qwen-Image on RunPod).
- **Target:** iPadOS 17+, landscape only (v1)
- **Current Phase:** Phase 1 — Prototype (Weeks 1-4)

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
cd backend && docker compose up -d # Local Postgres + Redis
cd backend && npm run migrate      # Run DB migrations
```

## Architecture Decisions (Decided — Do Not Propose Alternatives)

**iOS:** SwiftUI for UI. PencilKit for drawing. Swift Concurrency (actors, async/await) — no Combine except PencilKit delegate bridging. URLSession for networking — no third-party HTTP libs. SwiftData for persistence. Core Image + vImage for image processing. 3 local Swift packages via SPM. AppCoordinator (@Observable) injected via environment.

**Backend:** TypeScript + Fastify — no Express. PostgreSQL via Supabase with Drizzle ORM. Redis via Upstash. Sign in with Apple + JWT — no other auth providers. Cloudflare R2 + CDN for image storage. Railway for hosting. Single monolith with internal module boundaries — not microservices. Each module is a Fastify plugin.

## Navigation & Persistence

State-based navigation via `AppCoordinator.currentScreen` (`.gallery` | `.drawing`). No NavigationStack.

- **Gallery view** (`GalleryView`) — root screen when drawings exist. 2-column grid of tiles. Uses `@Query` to observe SwiftData directly.
- **Drawing view** (`DrawingView`, renamed from ContentView) — canvas + result split pane. Gallery button top-left navigates back.
- **Style picker** — `PromptStyle` model defines available styles (None, Studio Ghibli, 3D Render). Selected style's `promptSuffix` is appended to the user's prompt client-side before sending to backend. Style composition lives entirely on the client; backend is style-agnostic.
- **Drawing model** (`Drawing.swift`) — SwiftData `@Model` with `@Attribute(.externalStorage)` for all image blobs (PKDrawing data, background image, generated image, lineart, canvas thumbnail). Settings stored as fields (prompt, style ID, advanced params as JSON, seed lock).
- **Auto-save** — debounced 1s on stroke/prompt/settings changes, immediate on generation result. `saveCurrentDrawing()` guards against nil canvas exports.
- **Pending-state pattern** — `CanvasViewModel.setPendingState()` queues canvas data before navigation; `attach()` applies it before the PKCanvasView delegate is set (no spurious change events).
- **Empty drawing cleanup** — `navigateToGallery()` deletes drawings with no content (no thumbnail, no prompt, no generated image).

## Module Dependencies

```
CanvasModule       → (none)
NetworkModule      → (none)
ResultModule       → (none)
AppCoordinator     → all 3 modules + SwiftData
```
Data flows one direction: Canvas → Network → Result. Modules communicate through AppCoordinator. No circular dependencies. No module imports the main app target.

## Critical Constraints (NEVER Violate)

1. **Canvas responsiveness is sacred.** PencilKit rendering NEVER depends on network/generation state. Target <16ms stroke latency. Any synchronous generation-related work on main thread = P0 bug.
2. **Latest-request-wins.** Only the newest generation result may update the UI. Every response checked against current latest request ID before display.
3. **Never clear the right pane.** Always keep last successful image visible. Never show blank after first successful generation.
4. **No secrets on client.** Provider API keys and URLs (ComfyUI) backend only. Client uses JWT. Client NEVER calls inference providers directly.
5. **Content safety before external testing.** NSFW output filter + prompt input filter must be operational before any external TestFlight build.
6. **Privacy by design.** Sketch data is ephemeral on server — deleted after generation response. Not stored, not trained on, not shared. Exception: flagged content in content_filter_log.
7. **App Store compliance.** Must include: first-launch AI disclosure consent (guideline 5.1.2(i)), age gate (1.2.1(a)), content filtering, "Report this image" button.
8. **Requests must be cancellable.** Both client-side (Task.cancel()) and server-side (/v1/cancel).

## ComfyUI Workflow

Two representations of the same pipeline exist. They must stay in sync.

- **API format** (`backend/src/modules/providers/comfyui-workflow-api.json`) — source of truth in the repo. Default parameter values in this file are the production defaults.
- **UI format** (on the pod) — for visual editing. Lives only on the pod, never in the repo.

When tuning parameters in the ComfyUI web UI, sync the changes back to the API template in the repo. Only one UI workflow should exist on the pod.

## Key References

| When | Read |
|------|------|
| Content safety / App Store compliance | `documents/references/content-safety.md` |
| RunPod deploy, provider ops, workflow updates | `documents/references/provider-config.md` |
| Implementation decisions log | `documents/decisions.md` |
| Active plans / phase progress | `documents/plans/` |
| Product requirements | `PRD.md` |
| System architecture | `TECHNICAL_ARCHITECTURE.md` |
| Deploy/infra scripts | SSH into a live pod and verify paths before changing. Never guess — the `runpod/comfyui` image internals change without notice. |
| Remote file systems (pods, ComfyUI dirs) | Always SSH in and `ls`/`find` to confirm layout. Never assume paths. |

## Git Conventions

- **Branches:** `feature/module-short-desc`, `fix/module-short-desc`, `chore/desc`
- **Commits:** Conventional format — `feat(canvas): add snapshot export`, `fix(scheduler): discard stale preview`
- One logical change per commit. Prefix with module name when scoped.
