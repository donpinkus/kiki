# Threading Model

## Core Rule
No synchronous work on the main thread except PencilKit rendering and SwiftUI updates. If Instruments shows ANY generation-related work on the main thread, it is a P0 bug.

## Thread / Queue Assignments

| Thread / Queue | Work Performed | Priority | Notes |
|---|---|---|---|
| Main thread | PencilKit rendering, SwiftUI layout, user input handling | `.userInteractive` | NOTHING else. Sacred. |
| Preprocessing queue (serial) | Canvas snapshot capture, monochrome conversion, crop, resize | `.userInitiated` | vImage for hardware-accelerated ops |
| Auto-caption queue (serial) | Core ML VLM inference for sketch captioning | `.utility` | 200ms timeout; skip if exceeded |
| Network queue (concurrent) | HTTP/WebSocket I/O, request/response serialization | `.utility` | Managed by URLSession internally |
| Image decode queue (serial) | Download returned image, decode JPEG/PNG to UIImage | `.utility` | Use CGImageSource with kCGImageSourceShouldCacheImmediately |

## Swift Concurrency Mapping

```swift
// Preprocessing — detached task with userInitiated priority
Task(priority: .userInitiated) {
    let processed = await preprocessor.process(snapshot)
    // ...
}

// Auto-caption — utility priority
Task(priority: .utility) {
    let caption = try await captioner.caption(image)
    // ...
}

// Network — handled by URLSession (no manual queue needed)

// UI update — must be MainActor
@MainActor
func updateResultImage(_ image: UIImage) {
    // SwiftUI state update
}
```

## Image Pipeline Optimization

### Capture
- Preview: 512x512 max. Downscale from PencilKit native using vImage.
- Refine: 1024x1024. Only captured when refine timer fires (1200ms idle).

### Upload Format
- JPEG at 85% quality (minimizes payload size)

### Local Storage Format
- PNG (lossless) for gallery persistence

### Decode
- Use `CGImageSource` with `kCGImageSourceShouldCacheImmediately` to decode on background queue
- Hand a ready-to-render `CGImage` to the main thread

### Memory
- In-memory image cache capped at 20 images
- Flush cache on `UIApplication.didReceiveMemoryWarningNotification`
- Reduce snapshot resolution under memory pressure (512→384 for preview)

## Actor Isolation

```swift
// GenerationScheduler is an actor — all state mutations are thread-safe
actor GenerationScheduler {
    private var latestRequestId: UUID?
    private var activePreviewTask: Task<Void, Never>?
    private var activeRefineTask: Task<Void, Never>?

    // All methods are implicitly async when called from outside the actor
    func schedulePreview(_ sketch: ProcessedSketch) { ... }
    func scheduleRefine(_ sketch: ProcessedSketch) { ... }
    func cancelAll() { ... }
}
```

## Performance Targets

| Metric | Target | Unacceptable |
|---|---|---|
| Canvas stroke latency | <8ms (p50), <16ms (p95) | >16ms = P0 bug |
| Preprocessing | 20-50ms | >100ms = investigate |
| Auto-caption | <200ms | >500ms = skip and use generic prompt |
| Image decode | 50-100ms | >200ms = optimize decode pipeline |

## Profiling Checklist
- Run Instruments Time Profiler on oldest supported iPad (iPad 9th gen)
- Verify zero main thread work from generation code
- Check for memory leaks in image pipeline
- Monitor peak memory during extended drawing sessions
