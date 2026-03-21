# Kiki — iPad Sketch-to-Image App

iPad-native drawing app. User sketches on left pane, AI-generated image appears on right pane. PencilKit + ComfyUI (Qwen-Image on RunPod).
- **Target:** iPadOS 17+, landscape only (v1)
- **Current Phase:** Phase 1 — Prototype (Weeks 1-4)
- **Source docs:** `PRD.md`, `TECHNICAL_ARCHITECTURE.md`

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

## Project Layout

```
kiki/
  ios/                    # iPad app (SwiftUI + PencilKit)
    Kiki/App/             # Entry point, AppCoordinator, ContentView
    Kiki/Views/           # SwiftUI views (split-screen, controls, onboarding)
    Kiki/Resources/       # Assets, config files
    Packages/             # 3 local Swift packages (SPM)
      CanvasModule/       # PencilKit canvas, stroke tracking, snapshot export
      NetworkModule/      # REST + WebSocket, auth token management
      ResultModule/       # Image display, transitions, gallery (SwiftData)
  backend/                # Node.js API (Fastify + TypeScript)
    src/routes/           # Endpoint handlers
    src/modules/          # auth, quota, orchestrator, providers, safety
    src/models/           # Drizzle ORM schema
    src/config/           # Env vars, provider routing, blocklist
    tests/                # Unit + integration tests
  documents/              # Project docs (see Doc Routing below)
```

## Architecture Decisions (Decided — Do Not Propose Alternatives)

**iOS:** SwiftUI for UI. PencilKit for drawing. Swift Concurrency (actors, async/await) — no Combine except PencilKit delegate bridging. URLSession for networking — no third-party HTTP libs. SwiftData for persistence. Core Image + vImage for image processing. 5 local Swift packages via SPM. AppCoordinator (@Observable) injected via environment. GenerationScheduler is a Swift actor.

**Backend:** TypeScript + Fastify — no Express. PostgreSQL via Supabase with Drizzle ORM. Redis via Upstash. Sign in with Apple + JWT — no other auth providers. Cloudflare R2 + CDN for image storage. Railway for hosting. Single monolith with internal module boundaries — not microservices. Each module is a Fastify plugin.

## ComfyUI Workflow

Two representations of the same pipeline exist. They must stay in sync.

- **API format** (`backend/src/modules/providers/comfyui-workflow-api.json`) — the source of truth in the repo. The backend clones this template, injects per-request values (prompt, sketch image, seed), and sends it to ComfyUI's `/prompt` endpoint. Default parameter values in this file are the production defaults.
- **UI format** (`kiki-workflow-<date>.json` on the pod at `/workspace/runpod-slim/ComfyUI/user/default/workflows/`) — for visual editing in ComfyUI's web UI. Lives only on the pod, never in the repo.

When tuning parameters in the ComfyUI web UI, sync the changes back to the API template in the repo. When changing defaults in the API template, update the UI workflow on the pod. Only one UI workflow should exist on the pod — delete old versions to avoid confusion.

## Module Dependencies

```
CanvasModule       → (none)
NetworkModule      → (none)
ResultModule       → (none)
AppCoordinator     → all 3 modules
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

## Doc Routing — Read Before Implementing

| Task | Read First |
|------|-----------|
| SwiftUI views | `documents/references/coding-conventions.md` |
| Backend endpoints | `documents/references/api-contracts.md` |
| GenerationScheduler | `documents/references/generation-timing.md`, `threading-model.md` |
| Provider adapters | `documents/references/provider-config.md`, `api-contracts.md` |
| Content safety | `documents/references/content-safety.md` |
| Data models | `documents/references/data-models.md` |
| Error states/UX | `documents/references/error-handling.md` |
| Style presets | `documents/references/style-presets.md` |
| State/data flow | `documents/references/state-management.md`, `module-architecture.md` |
| Implementation decision | Log in `documents/decisions.md` |
| Starting new work | Check `documents/plans/` for active plans |
| ComfyUI workflow parameters | Both formats (API in repo, UI on pod) must stay in sync. See "ComfyUI Workflow" section above. Compare with the script from this session if unsure whether they've drifted. |
| Deploy/infra scripts (`setup-pod.sh`, `deploy-pod.yml`, `create-pod.sh`) | SSH into a live pod (`runpodctl pod list`) and verify paths/binaries before changing. Never guess from Dockerfiles or docs — the `runpod/comfyui` image internals change without notice. |
| Any work involving remote file systems (pods, servers, ComfyUI directories) | Never assume file paths or directory structures. Always SSH in and `ls`/`find` to confirm the actual layout before writing, copying, or referencing files. This applies to ComfyUI internals (workflows, models, custom nodes), pod volumes, and any non-local file system. |

## Git Conventions

- **Branches:** `feature/module-short-desc`, `fix/module-short-desc`, `chore/desc`
- **Commits:** Conventional format — `feat(canvas): add snapshot export`, `fix(scheduler): discard stale preview`
- One logical change per commit. Prefix with module name when scoped.

## Phase 1 Checklist — Prototype

- [ ] Xcode project with SwiftUI app shell
- [ ] PencilKit canvas in split-screen layout
- [ ] Basic toolbar (brush, eraser, undo, clear)
- [ ] SketchPreprocessor (snapshot, monochrome, crop, resize)
- [ ] ResultView with loading/error/empty states
- [ ] GenerationScheduler actor (debounce, cancel, staleness)
- [ ] NetworkModule REST client
- [ ] Backend Fastify project scaffold
- [ ] POST /v1/generate endpoint
- [x] ~~fal.ai provider adapter~~ → ComfyUI adapter (Qwen-Image + InstantX ControlNet)
- [ ] POST /v1/cancel endpoint
- [ ] Stale job tracking (Redis)
- [x] ~~Refine mode (SDXL ControlNet via fal.ai)~~ → Qwen-Image 20B via ComfyUI on RunPod
- [ ] Prompt input field + style preset chips
- [ ] Prompt template system
- [ ] End-to-end: draw → preview → refine loop
