# Technical Architecture & Engineering Plan — iPad Sketch-to-Image Application

> **Companion to PRD v2.0 — March 2026** | Confidential — Engineering Team Only

| **Field**      | **Value**                                                            |
|----------------|----------------------------------------------------------------------|
| Document Owner | Engineering Lead                                                     |
| Audience       | iOS Engineers, Backend Engineers, Infra/DevOps, Engineering Managers |
| Companion PRD  | iPad Sketch-to-Image App — PRD v2.0                                  |
| Last Updated   | March 8, 2026                                                        |

## 1. Scope & Guiding Constraints

This document describes the system architecture, module boundaries, data flows, key technical decisions, and engineering milestone plan for the Sketch-to-Image iPad app. It is the engineering companion to the PRD v2.0 and is owned by the engineering team. Implementation details for individual features will be captured in separate feature specs and Jira epics as work begins.

### 1.1 Guiding Constraints

- **Canvas responsiveness is sacred.** Drawing latency must remain under 16ms (one frame at 60 fps) regardless of what the network or generation pipeline is doing. PencilKit rendering and generation I/O must be completely decoupled.

- **Provider portability.** The model inference landscape is shifting fast. The backend must be able to swap providers (fal.ai, Replicate, self-hosted) without client changes and ideally without a deployment.

- **Ship fast, iterate on quality.** Phase 1 (prototype) should be demoable in 4 weeks. We optimize for time-to-first-preview, not perfect polish. Features like crossfade, seed lock, and gallery polish come in Phase 4.

- **Apple ecosystem alignment.** SwiftUI, PencilKit, Swift Concurrency, SwiftData. No React Native, no Flutter, no cross-platform shortcuts. This is an iPad-native product.

- **Cost awareness.** Every generation costs real money. The architecture must support rate limiting, quota enforcement, request cancellation, and stale-job cleanup from day one, not as an afterthought.

## 2. System Architecture Overview

### 2.1 High-Level Architecture

The system is a three-tier architecture: iPad client, backend API, and external model providers. The iPad client handles all drawing, UI, request scheduling, and local persistence. The backend API handles authentication, quota enforcement, content safety filtering, request routing, and provider abstraction. Model providers (fal.ai primary, Replicate fallback) handle GPU inference.

The data flow for a single generation cycle is:

| **Step** | **Component**                             | **Action**                                                                              | **Latency Budget**                  |
|----------|-------------------------------------------|-----------------------------------------------------------------------------------------|-------------------------------------|
| 1        | iPad Client — Canvas Module               | User draws. PencilKit renders strokes immediately.                                      | 0ms (local)                         |
| 2        | iPad Client — Scheduler                   | Idle debounce timer fires (300ms for preview).                                          | 300ms                               |
| 3        | iPad Client — Preprocessor                | Capture PencilKit snapshot, flatten to monochrome, crop, resize to 512x512.             | 20–50ms                             |
| 4        | iPad Client — Auto-caption (if no prompt) | Run on-device VLM to generate hidden caption from sketch.                               | 100–200ms                           |
| 5        | iPad Client → Backend                     | POST /v1/generate or send via WebSocket. Payload: base64 sketch, prompt, style, params. | 50–100ms (network)                  |
| 6        | Backend — Gateway                         | Authenticate, validate, check quota, check content filter on prompt.                    | 10–20ms                             |
| 7        | Backend — Orchestrator                    | Route to provider adapter. Cancel any stale in-flight job for this session.             | 5–10ms                              |
| 8        | Backend — Provider Adapter                | Translate to fal.ai API format. Submit inference request.                               | 5ms                                 |
| 9        | fal.ai — Inference                        | Run SD 1.5 + LCM (preview) or SDXL + ControlNet Scribble (refine).                      | 150–500ms (preview) / 2–5s (refine) |
| 10       | Backend → iPad Client                     | Return image URL or bytes. Run NSFW classifier on output.                               | 50–100ms                            |
| 11       | iPad Client — Result Viewer               | Download image, decode off main thread, crossfade into right pane.                      | 50–100ms                            |

**End-to-end target for preview:** 700ms–1.5 seconds from idle-detect to image on screen.

**End-to-end target for refine:** 2.5–6 seconds from idle-detect to image on screen.

## 3. Tech Stack Decisions

### 3.1 Client (iPad)

| **Layer**           | **Technology**                                     | **Rationale**                                                                                                                                                                                                                 |
|---------------------|----------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| UI Framework        | SwiftUI                                            | Declarative, composable, first-class iPadOS support. Split-view layout maps naturally to SwiftUI’s NavigationSplitView or custom HStack geometry.                                                                             |
| Drawing Engine      | PencilKit                                          | Apple’s native drawing framework. Handles Apple Pencil pressure/tilt, palm rejection, undo/redo, and stroke serialization out of the box. Not customizable enough for Procreate-level features, but perfect for our v1 scope. |
| Async / Concurrency | Swift Concurrency (async/await, actors, TaskGroup) | Structured concurrency for managing debounce timers, network requests, and cancellation. Actors for thread-safe state management of the generation scheduler.                                                                 |
| Networking          | URLSession (REST) + URLSessionWebSocketTask (WS)   | Native. No third-party networking library needed for v1. WebSocket support is built into URLSession since iOS 13.                                                                                                             |
| Local Persistence   | SwiftData                                          | Apple’s modern persistence framework built on Core Data. Used for gallery/history (GeneratedImage entities) and session settings. Lightweight, zero-config for our data model.                                                |
| Image Processing    | Core Image + vImage (Accelerate)                   | Hardware-accelerated image preprocessing (monochrome conversion, contrast normalization, resize). Runs on GPU/Neural Engine, keeps main thread free.                                                                          |
| Auto-captioning     | Core ML (distilled BLIP-2 or Apple VLM)            | On-device vision-language model for no-prompt experience. Evaluate Apple’s built-in VLM APIs in iPadOS 18 first; fall back to a custom Core ML model if unavailable or insufficient.                                          |
| Analytics           | TelemetryDeck or custom (no Firebase)              | Privacy-first analytics. No PII collection. TelemetryDeck is GDPR-compliant and collects no device identifiers beyond hashed session IDs. If custom, use a lightweight event logger posting to our backend.                   |

### 3.2 Backend

| **Layer**          | **Technology**                                                    | **Rationale**                                                                                                                                                                                                                             |
|--------------------|-------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Language / Runtime | TypeScript on Node.js (or Go for performance-critical paths)      | TypeScript for development speed and team familiarity. Consider Go for the generation orchestrator if Node event loop becomes a bottleneck under high concurrency. Decision: start with TypeScript, profile, migrate hot paths if needed. |
| Framework          | Fastify                                                           | Faster than Express, built-in schema validation, first-class TypeScript support. Lightweight enough for a focused API surface (3–4 endpoints).                                                                                            |
| WebSocket          | Native ws library via Fastify plugin or a thin proxy to fal.ai WS | Proxies WebSocket connections to fal.ai’s real-time LCM endpoint. Adds auth and quota checks on connection establishment.                                                                                                                 |
| Database           | PostgreSQL (via Supabase or managed RDS)                          | Session tracking, quota usage, content filter logs, user accounts. Supabase adds auth and row-level security for free tier.                                                                                                               |
| Cache              | Redis (Upstash serverless Redis)                                  | Rate limit counters, daily quota tracking, recent request deduplication. Serverless Redis avoids managing infrastructure.                                                                                                                 |
| Content Safety     | Custom classifier + provider-side NSFW filter                     | Text prompt blocklist check (regex + small classifier). Image output NSFW check via a lightweight model (e.g., Falconsai/nsfw_image_detection on HuggingFace, or fal.ai’s built-in safety if available).                                  |
| Auth               | Sign in with Apple + JWT                                          | Required for App Store. JWTs for session tokens. No email/password for v1.                                                                                                                                                                |
| Hosting            | Railway or Render (container-based PaaS)                          | Fast deploy, autoscale, managed TLS. Avoid AWS/GCP complexity for v1. Migrate to ECS/Cloud Run if scale demands it.                                                                                                                       |
| Observability      | Grafana Cloud (Loki + Prometheus + Tempo)                         | Logs, metrics, traces. Track generation latency, error rates, provider health, quota usage. Set up alerts on p95 latency and error rate thresholds.                                                                                       |

### 3.3 Model Providers (External)

| **Provider**         | **Role**                             | **Endpoints Used**                                                                                                                         | **Pricing Model**                                                              |
|----------------------|--------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------|
| fal.ai (primary)     | Preview + Refine generation          | REST: fal-ai/lcm-sd15-i2i (preview), fal-ai/stable-diffusion-xl-controlnet (refine). WebSocket: wss://...lcm-sd15-i2i (real-time preview). | Per GPU-second (~\$0.001/sec). Preview ~\$0.003/image, Refine ~\$0.02/image.   |
| Replicate (fallback) | Failover for both preview and refine | jagilley/controlnet-scribble (SD 1.5), black-forest-labs/flux-canny-pro (FLUX).                                                            | Per-prediction pricing. Scribble ~\$0.003/image, FLUX Canny Pro ~\$0.03/image. |

## 4. Client Architecture

### 4.1 Module Overview

The client is organized into five modules with clear boundaries. Each module has a single owner and communicates with others through well-defined protocols (Swift protocols, not runtime protocols). The goal is that any module can be tested in isolation.

| **Module**         | **Responsibilities**                                                                                                | **Key Types**                                                            | **Dependencies**         |
|--------------------|---------------------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------|--------------------------|
| CanvasModule       | Render PencilKit canvas. Track stroke changes. Export canvas snapshot as UIImage. Undo/redo. Clear.                 | CanvasView (SwiftUI), CanvasViewModel, SketchSnapshot                    | None (fully independent) |
| PreprocessorModule | Convert PencilKit drawing to generation-ready image. Monochrome flatten, crop, resize. Auto-caption via Core ML.    | SketchPreprocessor, AutoCaptioner, ProcessedSketch                       | Core ML model bundle     |
| SchedulerModule    | Debounce user input. Manage preview/refine timers. Cancel stale requests. Enforce latest-request-wins. Track quota. | GenerationScheduler (actor), GenerationRequest, SchedulerState           | NetworkModule            |
| NetworkModule      | HTTP and WebSocket communication with backend. Request/response serialization. Auth token management.               | APIClient, WebSocketClient, GenerateRequest, GenerateResponse            | URLSession               |
| ResultModule       | Display generated images. Animate transitions (crossfade). Show loading/error states. Gallery/history.              | ResultView (SwiftUI), ResultViewModel, GeneratedImage (SwiftData entity) | SwiftData                |

### 4.2 Module Interaction Flow

The modules interact through a unidirectional data flow pattern, coordinated by a top-level AppCoordinator that owns the app’s shared state:

1.  **CanvasModule** emits canvasDidChange events (published via Combine or AsyncStream) whenever strokes are added, removed, or modified.

2.  **SchedulerModule** subscribes to canvas change events. On each event, it resets the debounce timer. When the timer fires, it asks the **PreprocessorModule** to prepare a ProcessedSketch.

3.  **PreprocessorModule** captures a snapshot from PencilKit, runs image preprocessing, and (if no user prompt is set) runs the auto-captioner. Returns a ProcessedSketch containing the image data and derived caption.

4.  **SchedulerModule** constructs a GenerationRequest and hands it to the **NetworkModule** for submission. It also cancels any prior in-flight request for the same mode (preview or refine).

5.  **NetworkModule** sends the request to the backend (REST or WebSocket). On response, it publishes a GenerationResult to the **ResultModule**.

6.  **ResultModule** receives the result, validates that the requestId matches the latest expected ID (discards stale results), downloads the image, and updates the UI with a crossfade transition.

### 4.3 State Management

State is divided into three scopes to avoid a single monolithic state object:

| **Scope**        | **Owner**                    | **Contents**                                                                                                                 | **Persistence**                                                   |
|------------------|------------------------------|------------------------------------------------------------------------------------------------------------------------------|-------------------------------------------------------------------|
| UI State         | AppCoordinator (@Observable) | Current tool, prompt text, style preset, auto/manual mode, loading/error flags, divider position.                            | UserDefaults (lightweight preferences)                            |
| Canvas State     | CanvasViewModel              | Current PKDrawing, last exported sketch hash, undo/redo availability.                                                        | In-memory only (PKDrawing is not persisted across sessions in v1) |
| Generation State | GenerationScheduler (actor)  | Latest request ID, in-flight preview request ID, in-flight refine request ID, latest successful image URL, pinned image URL. | In-memory only                                                    |
| History State    | SwiftData ModelContext       | Array of GeneratedImage entities with metadata.                                                                              | SwiftData (SQLite on disk)                                        |
| Quota State      | QuotaManager                 | Daily generation count, tier limits, reset timestamp.                                                                        | UserDefaults + server-side verification                           |

### 4.4 The GenerationScheduler Actor (Critical Component)

The GenerationScheduler is the most important piece of client-side logic. It is implemented as a Swift actor to guarantee thread-safe state mutations. Its responsibilities:

- **Debouncing:** Maintains two timers (preview at 300ms, refine at 1200ms). Each canvas change event resets both timers.

- **Request lifecycle:** When a timer fires, the scheduler creates a new GenerationRequest with a UUID, increments the latest request ID counter, and submits via NetworkModule.

- **Cancellation:** When a new request is created for a given mode, the scheduler cancels the prior in-flight request for that mode by (a) calling Task.cancel() on the Swift concurrency task, and (b) sending a /v1/cancel request to the backend.

- **Staleness check:** When a response arrives, the scheduler compares the response’s requestId against the current latest request ID. If they don’t match, the response is discarded silently.

- **Quota enforcement:** Before submitting a request, the scheduler checks the local quota counter. If the user has exceeded their daily limit, it publishes a quota-exceeded event instead of making a network call.

- **Mode coordination:** A successful preview does not cancel an in-flight refine for the same sketch. A new sketch change cancels both.

## 5. Backend Architecture

### 5.1 Service Topology

For v1, the backend is a single deployable service (monolith) with internal module boundaries. This avoids the operational overhead of microservices while maintaining clean separation of concerns. The service exposes 4 endpoints (generate, cancel, history, health) and a WebSocket upgrade path.

### 5.2 Module Decomposition

| **Module**                   | **Responsibilities**                                                                                                            | **Key Design Notes**                                                                                                                                                                                           |
|------------------------------|---------------------------------------------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Auth Layer                   | Validate Sign in with Apple tokens. Issue and verify JWTs. Attach user context to requests.                                     | Middleware on all routes. JWTs have 1-hour expiry, refresh via silent re-auth.                                                                                                                                 |
| API Gateway                  | Route requests. Validate payload schemas (Fastify JSON schema). Rate limit by user ID.                                          | Rate limit: 10 req/sec per user (burst), 150/day for free tier, tracked in Redis.                                                                                                                              |
| Quota Manager                | Track daily generation counts per user and tier. Enforce limits. Reset at midnight UTC.                                         | Redis counter with TTL. Server-side is source of truth; client caches for UX.                                                                                                                                  |
| Content Filter               | Screen prompt text against blocklist. Classify generated images for NSFW content.                                               | Prompt filter: regex blocklist + lightweight text classifier. Image filter: run a small NSFW classifier on the returned image before forwarding to client. Log all filtered events.                            |
| Generation Orchestrator      | Decide preview vs. refine pipeline. Cancel stale jobs. Track in-flight requests per session. Dispatch to provider adapter.      | Maintains an in-memory map of sessionId → {activePreviewJobId, activeRefineJobId}. On new request: cancel stale, update map, dispatch.                                                                         |
| Provider Adapter (fal.ai)    | Translate normalized GenerateRequest into fal.ai API format. Submit. Poll or stream result. Return normalized GenerateResponse. | Handles fal.ai’s queue API (submit → poll) for REST, and direct WebSocket streaming for preview fast path. Implements retry with exponential backoff on transient errors.                                      |
| Provider Adapter (Replicate) | Same interface as fal.ai adapter. Translates to Replicate’s prediction API.                                                     | Used as automatic failover if fal.ai returns errors for >30 seconds (circuit breaker pattern). Also used for FLUX models if we A/B test alternative pipelines.                                                |
| Provider Router              | Selects which provider adapter to use based on mode, health, and configuration.                                                 | Config-driven routing: { preview: “fal”, refine: “fal”, fallback: “replicate” }. Feature flags for A/B testing providers.                                                                                      |
| Image Storage                | Proxy and cache generated images. Serve signed URLs to client.                                                                  | Store generated images in S3-compatible object storage (Cloudflare R2 for cost). Signed URLs with 7-day expiry. CDN (Cloudflare) in front.                                                                     |
| Observability                | Structured logging, metrics emission, distributed tracing.                                                                      | Every request gets a traceId. Log: requestId, sessionId, userId, mode, provider, latencyMs, status, contentFilterResult. Metrics: generation_latency_ms histogram, generation_count counter, error_rate gauge. |

### 5.3 Provider Failover & Circuit Breaker

The Provider Router implements a circuit breaker pattern to handle provider outages gracefully:

- **Closed (normal):** All requests go to the primary provider (fal.ai).

- **Open (failover):** If the primary provider returns 5 consecutive errors or p95 latency exceeds 10 seconds over a 60-second window, the circuit opens and all requests are routed to the fallback provider (Replicate).

- **Half-open (probe):** After 60 seconds in the open state, the router sends a single probe request to the primary. If it succeeds, the circuit closes. If it fails, the circuit stays open for another 60 seconds.

Circuit state is stored in Redis so it is shared across all backend instances.

### 5.4 WebSocket Proxy for Real-Time Preview

For the preview fast path, the backend acts as an authenticated proxy between the iPad client and fal.ai’s WebSocket LCM endpoint. The flow is:

7.  Client opens a WebSocket connection to our backend at /v1/generate/stream.

8.  Backend authenticates the connection (JWT in the initial HTTP upgrade headers).

9.  Backend opens a corresponding WebSocket connection to fal.ai’s LCM real-time endpoint using our API key.

10. Client sends sketch frames as binary WebSocket messages. Backend forwards them to fal.ai with prompt/style metadata.

11. fal.ai returns generated image frames. Backend runs the NSFW classifier, then forwards clean frames to the client.

12. If the fal.ai connection drops, backend transparently reconnects or falls back to REST.

**Key constraint:** The backend WebSocket proxy must add minimal latency (<20ms). It should not buffer or batch frames. The content safety check on the output image is the only processing step, and it must complete in <50ms to stay within the latency budget.

## 6. Data Model

### 6.1 Client-Side Entities (SwiftData)

| **Entity**     | **Field**           | **Type** | **Notes**                                     |
|----------------|---------------------|----------|-----------------------------------------------|
| DrawingSession | id                  | UUID     | Primary key                                   |
|                | createdAt           | Date     |                                               |
|                | updatedAt           | Date     |                                               |
|                | currentPrompt       | String?  | Nil if no user prompt                         |
|                | currentStylePreset  | String   | Enum raw value                                |
|                | currentAdherence    | Float    | Default 0.7                                   |
|                | currentSeed         | Int?     | Nil = random                                  |
|                | dividerPosition     | Float    | 0.0–1.0, default 0.55                         |
| GeneratedImage | id                  | UUID     | Primary key                                   |
|                | sessionId           | UUID     | FK to DrawingSession                          |
|                | createdAt           | Date     |                                               |
|                | mode                | String   | “preview” or “refine”                         |
|                | prompt              | String?  | User prompt (nil if auto-captioned)           |
|                | autoCaption         | String?  | VLM-generated caption                         |
|                | stylePreset         | String   |                                               |
|                | adherence           | Float    |                                               |
|                | seed                | Int      | Seed used by provider                         |
|                | sketchThumbnailPath | String   | Local file path to sketch thumbnail           |
|                | imagePath           | String   | Local file path to downloaded generated image |
|                | imageURL            | String?  | Remote signed URL (expires in 7 days)         |
|                | latencyMs           | Int      | End-to-end generation latency                 |
|                | provider            | String   | “fal” or “replicate”                          |
|                | wasSaved            | Bool     | User explicitly saved to gallery              |

### 6.2 Server-Side Tables (PostgreSQL)

| **Table**          | **Key Fields**                                                                                             | **Purpose**                                                                         |
|--------------------|------------------------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------------|
| users              | id, apple_user_id, tier, created_at                                                                        | User accounts from Sign in with Apple.                                              |
| usage_log          | id, user_id, date, preview_count, refine_count                                                             | Daily generation counts for quota enforcement and billing analytics.                |
| generation_events  | id, user_id, session_id, request_id, mode, provider, latency_ms, status, content_filter_result, created_at | Append-only event log for observability, debugging, and content safety auditing.    |
| content_filter_log | id, generation_event_id, filter_type (prompt\|image), result, categories, created_at                       | Detailed log of content filter decisions. Required for App Store compliance audits. |

**Note:** We do not store sketch images or prompts on the server beyond the lifecycle of the generation request, except in content_filter_log entries for flagged content. This is a privacy-by-design decision aligned with our App Store consent disclosures.

## 7. Performance Architecture

### 7.1 Client Performance

The fundamental performance constraint is that drawing must never compete with generation for main thread time. The architecture enforces this through strict thread isolation:

| **Thread / Queue**           | **Work Performed**                                                        | **Priority**                        |
|------------------------------|---------------------------------------------------------------------------|-------------------------------------|
| Main thread                  | PencilKit rendering, SwiftUI layout, user input handling. Nothing else.   | User-interactive (.userInteractive) |
| Preprocessing queue (serial) | Canvas snapshot capture, monochrome conversion, crop, resize.             | User-initiated (.userInitiated)     |
| Auto-caption queue (serial)  | Core ML VLM inference for sketch captioning.                              | Utility (.utility)                  |
| Network queue (concurrent)   | HTTP/WebSocket I/O. Request serialization. Response deserialization.      | Utility (.utility)                  |
| Image decode queue (serial)  | Download returned image. Decode JPEG/PNG to UIImage. Prepare for display. | Utility (.utility)                  |

**Key rule:** No synchronous work on the main thread except PencilKit rendering and SwiftUI updates. All image processing, network I/O, and model inference happens on background queues using Swift Concurrency (Task, actor isolation). If profiling ever shows main thread work from generation-related code, it is a P0 bug.

### 7.2 Image Pipeline Optimization

- **Preview snapshot resolution:** 512x512 maximum. Downscale from PencilKit’s native resolution using vImage for hardware-accelerated resizing.

- **Refine snapshot resolution:** 1024x1024. Only captured when the refine timer fires (1200ms idle), so the extra processing time is acceptable.

- **Image format:** JPEG at 85% quality for upload (minimizes payload size). PNG for local gallery storage (lossless).

- **Returned image decoding:** Use CGImageSource with kCGImageSourceShouldCacheImmediately to decode on the background queue and hand a ready-to-render CGImage to the main thread.

- **Memory management:** Cap the in-memory image cache at 20 images. Flush cache proactively when UIApplication.didReceiveMemoryWarningNotification fires. Reduce snapshot resolution under memory pressure.

### 7.3 Backend Performance

- **Stateless request handling:** The backend is horizontally scalable. No sticky sessions. In-flight job tracking uses Redis, not local memory, so any instance can handle any request.

- **Stale job cancellation:** When the orchestrator receives a new request for a session that has an in-flight job, it sends a cancel signal to the provider (if the provider supports it) and marks the old job as stale in Redis. The response handler checks this flag and discards stale results.

- **Warm provider connections:** The fal.ai WebSocket connection pool is maintained across requests. For REST, use HTTP/2 keep-alive connections with a pool size of 50.

- **Image proxy caching:** Generated images are stored in Cloudflare R2 and served via Cloudflare CDN. The backend returns a CDN URL, not a direct fal.ai URL, so we control caching and can enforce signed-URL expiry.

### 7.4 Latency Budget Breakdown

Target end-to-end preview latency: 1 second. Here is how the budget is allocated:

| **Phase**                | **Allocated Budget** | **Optimization Lever**                                                                         |
|--------------------------|----------------------|------------------------------------------------------------------------------------------------|
| Debounce wait            | 300ms (fixed)        | Could reduce to 200ms if it feels too slow, at the cost of more cancelled requests.            |
| Client preprocessing     | 50ms                 | vImage hardware acceleration. Pre-allocate output buffers.                                     |
| Auto-caption (on-device) | 150ms                | Use smallest viable Core ML model. Skip if user has typed a prompt.                            |
| Network round-trip       | 100ms                | WebSocket eliminates HTTP overhead. Backend co-located with provider region.                   |
| Backend processing       | 30ms                 | Quota check via Redis (1ms). Prompt filter (5ms). Routing (1ms). NSFW check on output (~20ms). |
| Provider inference       | 300ms                | fal.ai LCM at 4 steps. Already near-optimal. If slower, reduce to 2 steps or lower resolution. |
| Image download + decode  | 70ms                 | CDN-cached. JPEG decode on background thread.                                                  |
| Total                    | 1,000ms              |                                                                                                |

## 8. Content Safety Implementation

Content safety is not a feature; it is infrastructure. It must be operational before any external testing begins.

### 8.1 Prompt Filtering

- **Layer 1 — Blocklist:** A curated regex-based blocklist of terms and phrases. Maintained as a JSON config file, deployable without code changes. Covers explicit sexual content, violence, hate speech, and CSAM-adjacent terms.

- **Layer 2 — Text classifier:** A lightweight text classifier (e.g., OpenAI’s moderation endpoint or a self-hosted model) for prompts that evade the blocklist through obfuscation, misspelling, or coded language. Runs server-side only.

- **Behavior on trigger:** Return a 200 response with status “filtered” and a user-friendly message. Do not send the prompt to the inference provider. Do not count against the user’s quota.

### 8.2 Output Filtering

- **NSFW image classifier:** Run on every generated image before it is returned to the client. Use Falconsai/nsfw_image_detection (HuggingFace, ~20ms inference on CPU) or a comparable model deployed as a sidecar service. Must complete within 50ms to stay within latency budget.

- **Behavior on trigger:** Replace the image URL in the response with a blurred placeholder. Set contentFilterResult.flagged = true with category labels. Log the event to content_filter_log.

- **Provider-side safety:** fal.ai and Replicate may apply their own safety filters. Our output filter is an additional layer, not a replacement. If the provider filters an image (returns an error or blank), we propagate this as a “filtered” status to the client.

### 8.3 Audit & Reporting

- All filter events (prompt and image) are logged to the content_filter_log table with full metadata.

- Weekly automated report: filter trigger rate, false positive sample review, top blocked prompt patterns.

- User-facing “Report this image” button submits a report to a moderation queue (initially a shared Slack channel with structured payload; graduate to a proper moderation tool in v2).

## 9. Infrastructure & Deployment

### 9.1 Environments

| **Environment** | **Purpose**                                | **Provider Routing**                                            | **Deployment**                                                          |
|-----------------|--------------------------------------------|-----------------------------------------------------------------|-------------------------------------------------------------------------|
| Local dev       | Individual engineer development            | Mock provider (returns sample images with configurable latency) | Docker Compose: backend + Redis + Postgres                              |
| Staging         | Integration testing, QA, TestFlight builds | fal.ai (sandbox/dev key with rate limits)                       | Railway preview deployments (auto-deploy on PR merge to staging branch) |
| Production      | App Store release                          | fal.ai (production key) + Replicate (failover key)              | Railway production with autoscale (min 2 instances, max 10)             |

### 9.2 CI/CD Pipeline

- **Client (iOS):** GitHub Actions → Xcode Cloud. On PR: build + unit tests + SwiftLint. On merge to main: build + UI tests + TestFlight deploy. On tag: App Store submission.

- **Backend:** GitHub Actions. On PR: lint + unit tests + integration tests (against mock providers). On merge to main: auto-deploy to staging. On tag: deploy to production with canary (10% traffic for 30 minutes, then full rollout).

### 9.3 Configuration Management

Feature flags and provider routing configuration are stored in a JSON config file in the backend repo and loaded at startup. For v1, we do not need a runtime feature flag service. Configuration changes require a deploy, which takes <3 minutes on Railway. If we need runtime config changes (e.g., emergency provider switch), we add a Redis-backed config override that can be set via an admin endpoint.

### 9.4 Secrets Management

- Provider API keys (fal.ai, Replicate) stored in Railway environment variables. Never in code.

- Apple Sign in with Apple private key stored in Railway environment variables.

- JWT signing secret stored in Railway environment variables.

- No secrets on the client. The client authenticates via Sign in with Apple and receives a JWT from our backend. All provider API calls go through our backend, never directly from the client.

## 10. Technical Risks & Mitigations

| **Risk**                                                           | **Severity** | **Likelihood** | **Mitigation**                                                                                                                                                                                                |
|--------------------------------------------------------------------|--------------|----------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| fal.ai LCM endpoint latency exceeds 1s consistently                | High         | Medium         | Fallback to lower step count (2 steps). Reduce preview resolution to 384x384. If persistent, evaluate Replicate LCM or self-hosted inference on RunPod.                                                       |
| fal.ai outage during peak usage                                    | High         | Low            | Circuit breaker auto-failover to Replicate within 30 seconds. Backend health check endpoint monitors provider status.                                                                                         |
| PencilKit snapshot capture causes frame drops                      | Critical     | Low            | Profile on oldest supported iPad (iPad 9th gen). Snapshot capture must happen off-main-thread. If PencilKit’s drawing(from:) is slow, use a lower-fidelity capture method.                                    |
| Auto-captioning VLM too slow on older iPads                        | Medium       | Medium         | Set a 200ms timeout. If exceeded, skip auto-caption and use a generic style-based prompt (“A \[style\] illustration”). Consider server-side captioning as alternative.                                        |
| App Store rejection due to AI content concerns                     | High         | Medium         | Pre-submit App Store review request. Ensure consent screen, privacy policy, age gate, and content filter are all in place before first submission. Prepare a document explaining our content safety approach. |
| Inference cost overruns from free tier abuse                       | Medium       | High           | Rate limit by device fingerprint + Apple account. Daily quota hard-enforced server-side. Monitor cost per user cohort weekly. Adjust free tier limits if CAC exceeds \$40.                                    |
| ControlNet Scribble produces poor results from very rough sketches | Medium       | Medium         | A/B test conditioning strength defaults. Provide a “more creative” / “more faithful” slider. Consider adding a sketch cleanup preprocessor (HED or PidiNet edge detection) before ControlNet.                 |
| WebSocket connection instability on cellular networks              | Medium       | Medium         | Automatic fallback to REST. Reconnect with exponential backoff. Client-side connection health monitor with heartbeat every 15 seconds.                                                                        |

## 11. Engineering Milestone Plan

This plan covers Phases 1–3 (Prototype through Launch, weeks 1–13). Phases 4–5 will be planned after launch based on user feedback and metric performance. The plan assumes a team of 2 iOS engineers, 1 backend engineer, and 1 part-time designer.

### Phase 1: Prototype (Weeks 1–4)

**Goal:** Validate the core interaction loop end-to-end. Demoable to stakeholders by end of week 4.

| **Week** | **iOS (2 engineers)**                                                                                                                                                 | **Backend (1 engineer)**                                                                                                                           | **Milestone**                                                                                                |
|----------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------|
| 1        | Set up Xcode project, SwiftUI app shell, PencilKit canvas in split-screen layout. Basic toolbar (brush, eraser, undo, clear).                                         | Set up Node/Fastify project. Scaffold /v1/generate endpoint. Implement fal.ai provider adapter (REST, LCM preview only). Mock auth.                | Canvas renders. Backend returns a generated image from fal.ai given a hardcoded sketch.                      |
| 2        | Implement SketchPreprocessor (snapshot, monochrome, crop, resize). Wire canvas changes to preprocessor. Display static result image in right pane.                    | Implement generation orchestrator (single mode: preview). Request validation. Basic structured logging. Deploy to staging on Railway.              | End-to-end: draw on iPad → see a preview image appear on the right.                                          |
| 3        | Implement GenerationScheduler actor: debounce timer, latest-request-wins, cancellation. Wire to NetworkModule (REST). Implement ResultView with loading/error states. | Add /v1/cancel endpoint. Implement stale job tracking in Redis. Add refine mode to orchestrator (SDXL ControlNet via fal.ai). Basic quota counter. | Preview appears ~1s after drawing pause. Refine replaces it after longer pause. Stale results are discarded. |
| 4        | Add prompt input field. Add style preset chips (hardcoded 5 presets). Wire prompt/style changes as generation triggers. Polish split-screen layout, divider.          | Add SDXL ControlNet Scribble adapter for refine. Prompt template system (style-based prompt prefixes). Health check endpoint.                      | Stakeholder demo: full draw → preview → refine loop with prompt and style control.                           |

### Phase 2: MVP (Weeks 5–10)

**Goal:** Ship a cohesive, safe, App Store-submittable experience to TestFlight.

| **Week** | **iOS (2 engineers)**                                                                                                                                                     | **Backend (1 engineer)**                                                                                                                | **Milestone**                                                    |
|----------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------|
| 5        | Implement auto-captioning module (Core ML VLM). Integrate into scheduler: if no user prompt, run auto-caption before generation. Test on 20+ sketch types.                | Implement content safety: prompt blocklist, text classifier integration, NSFW image classifier. Add content_filter_log table.           | No-prompt experience works. Content safety filters operational.  |
| 6        | Implement Sign in with Apple flow. JWT token management. Quota display in UI (generations remaining today). Implement adherence slider.                                   | Implement Sign in with Apple verification. JWT issuance. User table. Quota manager with Redis-backed daily counters. Tier-based limits. | Auth flow complete. Free tier quota enforced end-to-end.         |
| 7        | Implement gallery/history using SwiftData. Save button on generated images. Gallery view with thumbnails and metadata. Sketch thumbnail capture and storage.              | Implement WebSocket proxy for preview fast path. Wire fal.ai WS endpoint through auth + content filter. Fallback to REST on WS failure. | Gallery functional. WebSocket preview path reduces latency.      |
| 8        | Implement first-launch consent screen (Apple 5.1.2(i) compliance). Age gate. Settings screen with privacy policy link. Error handling polish.                             | Implement Replicate provider adapter. Circuit breaker. Provider router with config-driven routing. Monitoring dashboards (Grafana).     | App Store compliance screens in place. Provider failover tested. |
| 9        | UI polish: crossfade transitions, loading shimmer, error toasts. Toolbar auto-hide. Accessibility (VoiceOver labels, Dynamic Type on controls). iPad Mini layout testing. | Image storage pipeline: R2 upload, CDN signed URLs, 7-day expiry. Performance profiling. Load testing (simulate 100 concurrent users).  | UX feels polished. Backend handles load.                         |
| 10       | TestFlight build. Internal dogfood (full team). Bug bash. Performance profiling on oldest supported iPad. Memory pressure testing.                                        | Staging environment hardening. Log retention policy. Alerting on error rate >5%, p95 latency >5s.                                     | TestFlight build to internal testers.                            |

### Phase 3: Launch Prep (Weeks 11–13)

**Goal:** App Store submission and public launch.

| **Week** | **iOS (2 engineers)**                                                                                                                                                 | **Backend (1 engineer)**                                                                                                | **Milestone**                 |
|----------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------|-------------------------------|
| 11       | External TestFlight (50–100 beta testers). Collect feedback. Fix critical bugs. Analytics event instrumentation (TelemetryDeck).                                      | Production environment setup. DNS, TLS, CDN. Production provider API keys. Runbook for common incidents.                | External beta live.           |
| 12       | Address beta feedback. App Store screenshot preparation. App Store listing copy. Privacy policy finalization. Pre-submission self-review against App Store checklist. | Capacity planning based on beta usage data. Autoscale configuration. Cost monitoring dashboard. On-call rotation setup. | Ready for submission.         |
| 13       | Submit to App Store. Monitor review. Address any review feedback. Prepare launch day monitoring plan.                                                                 | Launch day readiness: scale up to min 4 instances. Provider status monitoring. War room plan for first 48 hours.        | App Store submission. Launch. |

## 12. Pre-Work Engineering Spikes

These spikes should be completed in week 0 (before Phase 1 begins) or in parallel with early Phase 1 work. Each spike has a specific deliverable and timebox.

| **Spike**                                  | **Question to Answer**                                                                                                                                       | **Deliverable**                                                                                                                                                        | **Timebox** | **Owner**              |
|--------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-------------|------------------------|
| S1: fal.ai LCM Benchmark                   | What is the actual p50/p95 latency for SD 1.5 LCM via fal.ai at 4 steps and 512x512, using hand-drawn sketch inputs? How does it compare to Replicate?       | Benchmark report with 50 sketch inputs across 5 styles. Latency distribution. Quality assessment (1–5 scale on 10 outputs).                                            | 3 days      | Backend eng            |
| S2: PencilKit Snapshot Performance         | How long does it take to capture and export a PencilKit canvas snapshot on the oldest supported iPad (iPad 9th gen)? Does it block the main thread?          | Profiling results from Instruments. Recommendation on capture method (drawing(from:) vs. UIGraphicsImageRenderer vs. Metal snapshot).                                  | 2 days      | iOS eng                |
| S3: Auto-Caption VLM Evaluation            | Can a distilled BLIP-2 model run on-device in <200ms on iPad Air M1? Is Apple’s built-in VLM API available in iPadOS 18 and suitable for sketch captioning? | Core ML model conversion test. Latency benchmarks on 3 iPad models. Caption quality assessment on 20 sketches. Go/no-go on on-device vs. server-side.                  | 3 days      | iOS eng                |
| S4: ControlNet Scribble Quality Assessment | How well does xinsir/controlnet-scribble-sdxl-1.0 handle our expected sketch types (rough blobs, stick figures, architectural outlines, detailed line art)?  | Visual quality assessment document: 50 input sketches x 5 style presets = 250 outputs. Annotated with quality scores. Identify sketch types that produce poor results. | 3 days      | Backend eng + designer |
| S5: Content Safety Classifier Speed        | Can we run an NSFW image classifier on generated images in <50ms server-side? What is the false positive rate on a test set of 200 safe images?             | Benchmark Falconsai/nsfw_image_detection. False positive/negative rates. Recommendation on threshold tuning.                                                           | 2 days      | Backend eng            |

## 13. Development Practices & Standards

### 13.1 Code Organization

- **iOS:** Swift Package Manager for module boundaries. Each of the 5 client modules (Canvas, Preprocessor, Scheduler, Network, Result) is a local Swift package with its own target and test target. The main app target depends on all 5 packages.

- **Backend:** Monorepo with clear directory structure: /src/routes, /src/modules (auth, quota, orchestrator, providers, safety), /src/models, /src/config, /tests. Each module exports a Fastify plugin.

### 13.2 Testing Strategy

| **Layer**         | **iOS**                                                                                                                                                                                                       | **Backend**                                                                                                                                                                                                                 |
|-------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Unit tests        | SketchPreprocessor (image transforms produce expected output). GenerationScheduler (debounce, cancellation, staleness). QuotaManager (limit enforcement). Target: 80% coverage on Scheduler and Preprocessor. | Quota manager (limit enforcement, reset logic). Content filter (blocklist matching, classifier integration). Provider adapters (request translation, response parsing). Target: 90% coverage on orchestrator and providers. |
| Integration tests | NetworkModule against a local mock server (using Swift’s URLProtocol mocking). End-to-end flow: canvas change → scheduler → network → result display (using SwiftUI previews with mock data).                 | API endpoint tests against a local Postgres + Redis. Provider adapter tests against fal.ai staging (gated, run manually). Circuit breaker tests with simulated failures.                                                    |
| UI tests          | XCUITest for critical flows: draw → see result, type prompt → see result, save to gallery, consent screen acceptance. Run on CI against simulator.                                                            | N/A                                                                                                                                                                                                                         |
| Performance tests | Instruments profiling on physical iPad. Memory leak detection. Main thread usage audit. Run monthly.                                                                                                          | Load tests with k6 or Artillery. Simulate 100 concurrent users generating continuously for 10 minutes. Run before each production deploy.                                                                                   |

### 13.3 Code Review Standards

- All code changes require 1 approving review before merge.

- Performance-sensitive code (scheduler, preprocessor, network layer) requires review from the tech lead.

- Any change to content safety filters requires review from the tech lead and product manager.

- Provider adapter changes require an accompanying integration test.

### 13.4 On-Call & Incident Response (Post-Launch)

- **On-call rotation:** Weekly rotation among the 3 engineers. On-call engineer monitors Grafana dashboards and Slack alert channel.

- **Alert thresholds:** Page on: error rate >10% for 5 minutes, p95 generation latency >10s for 5 minutes, provider circuit breaker open. Warn on: error rate >5%, p95 >6s, daily cost exceeding 150% of projected.

- **Runbook:** Documented procedures for: provider failover (manual circuit breaker override), emergency rate limit adjustment, content filter false positive spike, App Store emergency update.

## 14. Open Engineering Decisions

These decisions should be resolved during spikes or early Phase 1 work. Each has a designated decision-maker and deadline.

| **Decision**                                 | **Options**                                                                                                        | **Leaning Toward**                                                                                                                   | **Decision By** | **Owner**   |
|----------------------------------------------|--------------------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------|-----------------|-------------|
| Backend language                             | TypeScript (Fastify) vs. Go (Fiber/Chi)                                                                            | TypeScript for v1 (team familiarity, development speed). Revisit Go for hot paths if latency profiling warrants it.                  | Week 1          | Eng Lead    |
| Auto-caption: on-device vs. server           | Core ML on-device vs. server-side BLIP-2 via fal.ai/HuggingFace                                                    | On-device preferred (no extra latency, privacy-preserving). Depends on spike S3 results.                                             | Week 2          | iOS Lead    |
| WebSocket proxy vs. direct client-to-fal.ai  | Backend WebSocket proxy (adds auth + safety) vs. client connects directly to fal.ai (faster, but no safety filter) | Backend proxy (safety filter is non-negotiable for App Store). Accept the ~20ms latency cost.                                        | Week 1          | Eng Lead    |
| Image storage: R2 vs. S3 vs. provider-hosted | Cloudflare R2 (cheap, CDN-native) vs. AWS S3 vs. just use fal.ai’s 7-day hosted URLs                               | R2 for v1 (cost-effective, Cloudflare CDN built-in). Re-evaluate if storage costs grow beyond \$50/month.                            | Week 3          | Backend Eng |
| NSFW classifier: sidecar vs. inline          | Run classifier as a sidecar service vs. inline in the request handler                                              | Inline for v1 (simpler deployment). Move to sidecar if classifier latency exceeds 50ms or causes event loop blocking.                | Week 5          | Backend Eng |
| Analytics: TelemetryDeck vs. custom          | TelemetryDeck (privacy-first SaaS) vs. custom event logger to our Postgres                                         | TelemetryDeck for v1 (fast integration, no PII). Supplement with custom events for generation-specific metrics logged to our own DB. | Week 6          | iOS Lead    |

*End of document. This technical architecture is a living document. Feature-level implementation specs will be created as Jira epics during each phase. Architecture decisions will be recorded in ADRs (Architecture Decision Records) in the repo’s /docs/adr directory.*
