# Module Architecture

## iOS Client — 3 Local Swift Packages

### CanvasModule
- **Responsibilities:** Render PencilKit canvas. Track stroke changes. Export canvas snapshot as UIImage. Undo/redo. Clear.
- **Key Types:** `CanvasView` (SwiftUI), `CanvasViewModel`, `SketchSnapshot`
- **Dependencies:** None (fully independent)
- **Communication:** Emits `canvasDidChange` events via AsyncStream whenever strokes are added/removed/modified

### NetworkModule
- **Responsibilities:** HTTP communication with backend. Request/response serialization. Auth token management.
- **Key Types:** `APIClient`, `GenerateRequest`, `GenerateResponse`, `GenerationError`, `AdvancedParameters`
- **Dependencies:** URLSession (no third-party libs)

### ResultModule
- **Responsibilities:** Display generated images. Animate transitions (crossfade 200ms). Show loading/error/empty states. Phase-based progress tracking.
- **Key Types:** `ResultView` (SwiftUI), `ResultState`, `GenerationProgress`, `GenerationPhase`
- **Dependencies:** None
- **Rule:** Validates requestId matches latest expected ID before updating UI. Discards stale results silently.

## AppCoordinator — Central Orchestrator

AppCoordinator (`@MainActor @Observable`) owns all cross-module coordination:
- Debounce logic (1.5s after last canvas change)
- Generation request lifecycle (create → send → validate freshness → display)
- Latest-request-wins enforcement
- Auto-retrigger when canvas changes during generation
- At most one in-flight request at a time (single GPU constraint)

## Module Interaction Flow (Unidirectional)

1. **CanvasModule** emits `canvasDidChange` via AsyncStream
2. **AppCoordinator** subscribes, resets debounce timer on each event
3. When timer fires, AppCoordinator captures snapshot, encodes to JPEG, constructs `GenerateRequest`
4. **NetworkModule** sends to backend (REST), returns `GenerateResponse`
5. AppCoordinator validates freshness (requestId check), downloads image
6. **ResultModule** receives updated `ResultState`, crossfades into right pane

## Backend — Fastify Monolith with Module Plugins

### Auth Layer
- Validate Sign in with Apple tokens, issue/verify JWTs
- Middleware on all routes. JWTs have 1-hour expiry.
- Phase 1: mock auth (all requests accepted with placeholder user ID)

### API Gateway
- Route requests, validate payload schemas (Fastify JSON schema), rate limit by user ID
- Rate limit: 10 req/sec burst, daily limits per tier via Redis

### Content Filter
- Prompt: regex blocklist + lightweight text classifier
- Image: NSFW classifier on returned image before forwarding to client
- Log all filter events to `content_filter_log`

### Provider Adapter (ComfyUI on RunPod)
- Implements `ProviderAdapter` interface
- Loads workflow template from `comfyui-workflow-api.json`, injects per-request values (prompt, sketch image, seed, advanced parameters)
- Sends to ComfyUI's `/prompt` endpoint on RunPod pod
- Polls `/history` for completion, extracts output image URLs

### Image Storage
- Phase 1: Direct ComfyUI output URLs (temporary, on RunPod pod storage)
- Phase 2: Cloudflare R2 for storage, CDN for delivery with signed URLs
