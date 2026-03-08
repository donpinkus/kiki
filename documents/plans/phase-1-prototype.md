# Phase 1: Prototype (Weeks 1-4)

## Goal
Validate the core interaction loop end-to-end. Demoable to stakeholders by end of week 4: draw on iPad → see preview → see refined image.

## Prerequisites (Read Before Starting)
- `documents/references/module-architecture.md`
- `documents/references/generation-timing.md`
- `documents/references/api-contracts.md`
- `documents/references/coding-conventions.md`

## Week 1 — Foundation

### iOS
- [ ] Create Xcode project with SwiftUI app shell
- [ ] Set up 5 local Swift packages (CanvasModule, PreprocessorModule, SchedulerModule, NetworkModule, ResultModule) with Package.swift files
- [ ] Implement PencilKit canvas in split-screen layout (HStack: 55% canvas, 45% result)
- [ ] Basic floating toolbar: brush, eraser, undo, redo, clear
- [ ] Toolbar auto-hides after 3 seconds of inactivity

### Backend
- [ ] Set up Node/Fastify project with TypeScript
- [ ] Scaffold POST /v1/generate endpoint
- [ ] Implement fal.ai provider adapter (REST, LCM preview only)
- [ ] Mock auth (skip real auth for week 1)
- [ ] Docker Compose for local Postgres + Redis

### Milestone
Canvas renders strokes. Backend returns a generated image from fal.ai given a hardcoded sketch.

## Week 2 — Wire It Together

### iOS
- [ ] Implement `SketchPreprocessor` (snapshot capture, monochrome flatten, crop, resize to 512x512)
- [ ] Wire canvas changes to preprocessor
- [ ] Display static result image in right pane (`ResultView` basic implementation)
- [ ] Implement `APIClient` in NetworkModule (POST request to backend)

### Backend
- [ ] Implement generation orchestrator (single mode: preview)
- [ ] Request validation via Fastify JSON schema
- [ ] Basic structured logging (requestId, sessionId, latencyMs)
- [ ] Deploy to staging on Railway

### Milestone
End-to-end: draw on iPad → see a preview image appear on the right pane.

## Week 3 — Scheduler + Cancellation

### iOS
- [ ] Implement `GenerationScheduler` actor: debounce timers (300ms preview, 1200ms refine)
- [ ] Latest-request-wins logic (request ID tracking, stale response discard)
- [ ] Cancellation: Task.cancel() on new strokes + POST /v1/cancel
- [ ] Wire scheduler to NetworkModule (REST)
- [ ] Implement `ResultView` states: empty, generating, preview, refining, refined, error
- [ ] Loading shimmer overlay during generation
- [ ] Non-blocking error toasts

### Backend
- [ ] Add POST /v1/cancel endpoint
- [ ] Implement stale job tracking in Redis (sessionId → active job IDs)
- [ ] Add refine mode to orchestrator (SDXL ControlNet via fal.ai)
- [ ] Basic quota counter (Redis, no auth-based enforcement yet)

### Milestone
Preview appears ~1s after drawing pause. Refine replaces it after longer pause. Stale results discarded.

## Week 4 — Prompt + Style + Polish

### iOS
- [ ] Add prompt input field (text field below canvas, placeholder: "Describe what you're drawing, or leave blank")
- [ ] Add style preset chips (horizontally scrollable: Photoreal, Anime, Watercolor, Storybook, Fantasy, Ink, Neon)
- [ ] Wire prompt/style changes as immediate generation triggers (no debounce)
- [ ] Polish split-screen layout and resizable divider
- [ ] Crossfade transition (200ms) between old and new result images

### Backend
- [ ] Add SDXL ControlNet Scribble adapter for refine
- [ ] Prompt template system (style-based prompt prefixes from style-presets.md)
- [ ] GET /health endpoint
- [ ] Negative prompt injection (shared quality negative prompt)

### Milestone
Stakeholder demo: full draw → preview → refine loop with prompt and style control.

## Acceptance Criteria
- [ ] Drawing on canvas feels instant (no perceived lag)
- [ ] Preview appears within 2 seconds of stopping drawing
- [ ] Refined image replaces preview within 6 seconds of stopping drawing
- [ ] Typing a prompt and pressing return triggers new generation
- [ ] Changing style preset triggers new generation
- [ ] Continuing to draw cancels in-flight requests
- [ ] Only the latest result updates the right pane
- [ ] Error states show toast, keep last image visible
- [ ] Backend deploys to Railway staging
- [ ] End-to-end works on iPad Simulator

## Deferred to Phase 2
- Auth (Sign in with Apple)
- Content safety filters
- Auto-captioning (no-prompt VLM)
- Gallery/history (SwiftData)
- WebSocket preview fast path
- Consent screen / age gate
- Adherence slider
- Manual mode toggle
