# State Management

## Five State Scopes

State is divided into scopes to avoid a monolithic state object. Each scope has a clear owner and persistence strategy.

### 1. UI State — AppCoordinator (@Observable)

**Owner:** `AppCoordinator` — a `@MainActor @Observable` class injected into SwiftUI environment.

**Contains:**
- `currentTool: DrawingTool` — brush, eraser (enum)
- `promptText: String` — current prompt field value
- `selectedStylePreset: StylePreset` — current style selection
- `generationMode: GenerationToggle` — .auto or .manual
- `isLoading: Bool` — generation in progress
- `currentError: GenerationError?` — latest error for toast display
- `dividerPosition: CGFloat` — split-screen divider (0.0-1.0)
- `showConsentScreen: Bool` — first-launch consent
- `showSettings: Bool` — settings sheet

**Persistence:** UserDefaults for lightweight preferences (divider position, last style preset, auto/manual toggle). Not persisted: loading state, errors, prompt text.

### 2. Canvas State — CanvasViewModel

**Owner:** `CanvasViewModel` (within CanvasModule)

**Contains:**
- `currentDrawing: PKDrawing` — PencilKit's drawing object
- `lastSketchHash: String?` — hash of last exported snapshot (prevents duplicate generation)
- `canUndo: Bool` — derived from PencilKit
- `canRedo: Bool` — derived from PencilKit
- `isEmpty: Bool` — whether canvas has any strokes

**Persistence:** In-memory only. Drawings are NOT persisted across sessions in v1.

### 3. Generation State — GenerationScheduler (Actor)

**Owner:** `GenerationScheduler` — Swift actor

**Contains:**
- `latestRequestId: UUID?` — ID of the most recently created request
- `activePreviewRequestId: UUID?` — ID of the in-flight preview request
- `activeRefineRequestId: UUID?` — ID of the in-flight refine request
- `latestSuccessfulImageURL: URL?` — last good image for display
- `pinnedImageURL: URL?` — user-pinned image (v1 nice-to-have)

**Persistence:** In-memory only. Resets each session.

### 4. History State — SwiftData ModelContext

**Owner:** SwiftData

**Contains:**
- `GeneratedImage` entities with full metadata
- `DrawingSession` entities

**Persistence:** SwiftData (SQLite on disk). Survives app restarts.

### 5. Quota State — QuotaManager

**Owner:** `QuotaManager` (within SchedulerModule)

**Contains:**
- `dailyGenerationCount: Int` — today's generation count
- `dailyLimit: Int` — tier-based daily limit
- `resetTimestamp: Date` — midnight UTC
- `userTier: SubscriptionTier` — free, plus, or pro

**Persistence:** UserDefaults for client-side cache. Server-side Redis is source of truth. Client syncs on app launch and after each generation.

## State Flow Diagram

```
User Input (draw/prompt/style)
    ↓
AppCoordinator (UI State update)
    ↓
CanvasViewModel (Canvas State update, emit canvasDidChange)
    ↓
GenerationScheduler (Generation State: create request, manage timers)
    ↓
NetworkModule (send request)
    ↓
Response arrives
    ↓
GenerationScheduler (validate freshness, update latestSuccessfulImageURL)
    ↓
AppCoordinator (update isLoading, currentError)
    ↓
ResultViewModel (download image, update display)
    ↓
SwiftData (persist GeneratedImage if user saves)
```

## Rules
- AppCoordinator is the ONLY component that touches multiple state scopes
- Modules read/write only their own state scope
- State updates flow down (AppCoordinator → views). User actions flow up (views → AppCoordinator).
- No global singletons. AppCoordinator is injected via `@Environment`.
