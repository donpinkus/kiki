# Module Architecture

## iOS Client — 5 Local Swift Packages

### CanvasModule
- **Responsibilities:** Render PencilKit canvas. Track stroke changes. Export canvas snapshot as UIImage. Undo/redo. Clear.
- **Key Types:** `CanvasView` (SwiftUI), `CanvasViewModel`, `SketchSnapshot`
- **Dependencies:** None (fully independent)
- **Communication:** Emits `canvasDidChange` events via AsyncStream whenever strokes are added/removed/modified

### PreprocessorModule
- **Responsibilities:** Convert PencilKit drawing to generation-ready image. Monochrome flatten, crop to content bounds (10% padding), resize. Auto-caption via Core ML.
- **Key Types:** `SketchPreprocessor`, `AutoCaptioner`, `ProcessedSketch`
- **Dependencies:** Core ML model bundle
- **Input:** `SketchSnapshot` from CanvasModule (passed through AppCoordinator)
- **Output:** `ProcessedSketch` containing image data (base64) + derived caption

### SchedulerModule
- **Responsibilities:** Debounce user input. Manage preview/refine timers. Cancel stale requests. Enforce latest-request-wins. Track quota.
- **Key Types:** `GenerationScheduler` (actor), `GenerationRequest`, `SchedulerState`, `QuotaManager`
- **Dependencies:** NetworkModule
- **Critical:** This is the most important client-side component. Implemented as a Swift actor for thread-safe state.

#### GenerationScheduler Actor Responsibilities
- Maintains two timers: preview (300ms), refine (1200ms). Each canvas change resets both.
- Creates `GenerationRequest` with UUID when timer fires, increments latest request ID counter
- Cancels prior in-flight request for same mode via Task.cancel() + /v1/cancel
- Compares response requestId against current latest — discards if stale
- Checks local quota before submitting. Publishes quota-exceeded event if over limit.
- A successful preview does NOT cancel an in-flight refine for the same sketch. A new sketch cancels both.

### NetworkModule
- **Responsibilities:** HTTP and WebSocket communication with backend. Request/response serialization. Auth token management.
- **Key Types:** `APIClient`, `WebSocketClient`, `GenerateRequest`, `GenerateResponse`, `AuthManager`
- **Dependencies:** URLSession (no third-party libs)

### ResultModule
- **Responsibilities:** Display generated images. Animate transitions (crossfade 200ms). Show loading/error states. Gallery/history.
- **Key Types:** `ResultView` (SwiftUI), `ResultViewModel`, `GeneratedImage` (SwiftData @Model), `ImageCache`
- **Dependencies:** SwiftData
- **Rule:** Validates requestId matches latest expected ID before updating UI. Discards stale results silently.

## Module Interaction Flow (Unidirectional)

1. **CanvasModule** emits `canvasDidChange` via AsyncStream
2. **SchedulerModule** subscribes, resets debounce timers on each event
3. When timer fires, Scheduler asks **PreprocessorModule** to prepare a `ProcessedSketch`
4. **PreprocessorModule** captures snapshot, preprocesses, runs auto-caption if no user prompt
5. **SchedulerModule** constructs `GenerationRequest`, hands to **NetworkModule**, cancels prior in-flight
6. **NetworkModule** sends to backend (REST or WebSocket), publishes `GenerationResult`
7. **ResultModule** receives result, validates freshness, downloads image, crossfades into right pane

## Backend — Fastify Monolith with Module Plugins

### Auth Layer
- Validate Sign in with Apple tokens, issue/verify JWTs
- Middleware on all routes. JWTs have 1-hour expiry.

### API Gateway
- Route requests, validate payload schemas (Fastify JSON schema), rate limit by user ID
- Rate limit: 10 req/sec burst, daily limits per tier via Redis

### Quota Manager
- Track daily generation counts per user and tier
- Redis counter with TTL, resets at midnight UTC
- Server-side is source of truth; client caches for UX

### Content Filter
- Prompt: regex blocklist + lightweight text classifier
- Image: NSFW classifier on returned image before forwarding to client
- Log all filter events to `content_filter_log`

### Generation Orchestrator
- Preview vs. refine pipeline routing
- Cancel stale jobs. Track in-flight requests per session.
- In-memory map (Redis-backed): sessionId → {activePreviewJobId, activeRefineJobId}

### Provider Adapters (fal.ai + Replicate)
- Implement common `ProviderAdapter` interface
- Translate between internal `GenerateRequest`/`GenerateResponse` and provider-specific APIs
- fal.ai: REST (queue API: submit→poll) + WebSocket (real-time LCM)
- Replicate: REST (prediction API)

### Provider Router + Circuit Breaker
- Config-driven routing: `{ preview: "fal", refine: "fal", fallback: "replicate" }`
- Circuit breaker: Closed→Open after 5 consecutive errors or p95 >10s over 60s window
- Open→Half-open after 60s: sends probe request. Success→Closed. Failure→stays Open.
- Circuit state in Redis (shared across instances)

### Image Storage
- Cloudflare R2 for storage, CDN for delivery
- Signed URLs with 7-day expiry
- Backend returns CDN URL, not direct provider URL

### Observability
- Structured JSON logging with requestId, sessionId, userId
- Metrics: generation_latency_ms histogram, generation_count counter, error_rate gauge
- Grafana Cloud (Loki + Prometheus + Tempo)
