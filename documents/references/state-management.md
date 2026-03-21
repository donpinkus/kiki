# State Management

## State Scopes

State is divided into scopes to avoid a monolithic state object. Each scope has a clear owner and persistence strategy.

### 1. UI State — AppCoordinator (@Observable)

**Owner:** `AppCoordinator` — a `@MainActor @Observable` class injected into SwiftUI environment.

**Contains:**
- `currentTool: DrawingTool` — brush, eraser (enum)
- `toolSize: CGFloat` — current brush/eraser width
- `promptText: String` — current prompt field value
- `selectedStylePreset: StylePreset` — current style selection
- `resultState: ResultState` — empty, generating (with progress), preview, or error
- `dividerPosition: CGFloat` — split-screen divider (0.0-1.0)
- `advancedParameters: AdvancedParameters` — ComfyUI generation parameters
- `isSeedLocked: Bool` — whether to reuse seed from last generation

**Persistence:** Not persisted in Phase 1. Future: UserDefaults for preferences.

### 2. Canvas State — CanvasViewModel

**Owner:** `CanvasViewModel` (within CanvasModule)

**Contains:**
- `currentDrawing: PKDrawing` — PencilKit's drawing object
- `canUndo: Bool` — derived from PencilKit
- `canRedo: Bool` — derived from PencilKit
- `isEmpty: Bool` — whether canvas has any strokes

**Persistence:** In-memory only. Drawings are NOT persisted across sessions in v1.

### 3. Generation State — AppCoordinator (inline)

**Owner:** `AppCoordinator` (generation state is managed directly, not in a separate actor)

**Contains:**
- `currentRequestId: UUID?` — ID of the most recently created request
- `lastSuccessfulImage: UIImage?` — last good image for display
- `isGenerating: Bool` — whether a generation is in-flight
- `isCanvasDirty: Bool` — whether canvas changed during generation (triggers auto-retrigger)
- `debounceTask: Task?` — debounce timer (1.5s)

**Persistence:** In-memory only. Resets each session.

### 4. History State — SwiftData ModelContext (Phase 2)

**Owner:** SwiftData

**Contains:**
- `GeneratedImage` entities with full metadata
- `DrawingSession` entities

**Persistence:** SwiftData (SQLite on disk). Survives app restarts.

## State Flow Diagram

```
User Input (draw/prompt/style)
    ↓
AppCoordinator (UI State update)
    ↓
CanvasViewModel (Canvas State update, emit canvasDidChange)
    ↓
AppCoordinator (debounce 1.5s, then capture snapshot + JPEG encode)
    ↓
NetworkModule (send request to backend)
    ↓
Response arrives
    ↓
AppCoordinator (validate freshness via requestId, download image)
    ↓
ResultState updated → ResultView re-renders
    ↓
SwiftData (persist GeneratedImage if user saves — Phase 2)
```

## Rules
- AppCoordinator is the ONLY component that touches multiple state scopes
- Modules read/write only their own state scope
- State updates flow down (AppCoordinator → views). User actions flow up (views → AppCoordinator).
- No global singletons. AppCoordinator is injected via `@Environment`.
