# Phase 1: Prototype (Weeks 1-4)

## Goal
Validate the core interaction loop end-to-end. Demoable to stakeholders by end of week 4: draw on iPad → see preview → see refined image.

## Prerequisites
Read `CLAUDE.md` for architecture decisions, module dependencies, and critical constraints. Read the source code directly for API contracts, data models, and timing details.

## Week 1 — Foundation

### iOS
- [x] Create Xcode project with SwiftUI app shell
- [x] Set up 3 local Swift packages (CanvasModule, NetworkModule, ResultModule) with Package.swift files
- [x] Implement PencilKit canvas in split-screen layout (HStack: 55% canvas, 45% result)
- [x] Basic floating toolbar: brush, eraser, undo, redo, clear

### Backend
- [x] Set up Node/Fastify project with TypeScript
- [x] Scaffold POST /v1/generate endpoint
- [x] Implement ComfyUI provider adapter (Qwen-Image on RunPod)
- [x] Mock auth (skip real auth for week 1)
- [x] Docker Compose for local Postgres + Redis

### Milestone
Canvas renders strokes. Backend returns a generated image from ComfyUI given a sketch.

## Week 2 — Wire It Together

### iOS
- [x] Wire canvas snapshot capture and JPEG encoding
- [x] Display result image in right pane (`ResultView` implementation)
- [x] Implement `APIClient` in NetworkModule (POST request to backend)

### Backend
- [x] Request validation via Fastify JSON schema
- [x] Basic structured logging (requestId, sessionId, latencyMs)
- [ ] Deploy to staging on Railway

### Milestone
End-to-end: draw on iPad → see a preview image appear on the right pane.

## Week 3 — Debounce + Cancellation

### iOS
- [x] Implement debounce in AppCoordinator (1.5s after last canvas change)
- [x] Latest-request-wins logic (request ID tracking, stale response discard)
- [x] Auto-retrigger when canvas changes during in-flight generation
- [x] Implement `ResultView` states: empty, generating (with progress phases), preview, error
- [x] Phase-based progress tracking (preparing → uploading → downloading)

### Backend
- [ ] Add POST /v1/cancel endpoint
- [ ] Implement stale job tracking in Redis (sessionId → active job IDs)

### Milestone
Preview appears ~5-8s after drawing pause. Stale results discarded.

## Week 4 — Prompt + Style + Polish

### iOS
- [x] Add prompt input field
- [x] Add style preset chips (Photoreal, Anime, Watercolor, Storybook, Fantasy, Ink, Neon)
- [x] Wire prompt/style changes as generation triggers
- [x] Polish split-screen layout and resizable divider
- [x] Advanced parameters panel (ControlNet strength, CFG, steps, denoise, etc.)
- [x] Seed locking

### Backend
- [x] Prompt template system (style-based prompt prefixes)
- [x] GET /health endpoint
- [x] Accept advanced ComfyUI parameters from client

### Milestone
Stakeholder demo: full draw → preview loop with prompt, style, and advanced parameter control.

## Acceptance Criteria
- [x] Drawing on canvas feels instant (no perceived lag)
- [x] Preview appears after stopping drawing (debounced)
- [x] Typing a prompt and pressing return triggers new generation
- [x] Changing style preset triggers new generation
- [x] Continuing to draw queues re-generation after current completes
- [x] Only the latest result updates the right pane
- [x] Error states show in result pane, keep last image visible
- [ ] Backend deploys to Railway staging
- [x] End-to-end works on iPad Simulator

## Completed (originally deferred)
- [x] Gallery/history (SwiftData) — gallery home page with tile grid, auto-save, full drawing persistence
- [x] Manual mode toggle — auto/manual generation trigger in floating toolbar

## Deferred to Phase 2
- Auth (Sign in with Apple)
- Content safety filters
- Auto-captioning (no-prompt VLM)
- Refine mode (higher quality second pass)
- Consent screen / age gate
