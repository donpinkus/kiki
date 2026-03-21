# Generation Timing

## Debounce Configuration

| Timer | Duration | Triggers |
|---|---|---|
| Auto-generate | 1.5s of drawing inactivity | Qwen-Image 20B via ComfyUI on RunPod |

Phase 1 uses a single generation mode (preview). Refine mode deferred to Phase 2.

## Scheduling Rules

1. **New strokes reset the debounce timer.** Any canvas change event restarts the 1.5s countdown.
2. **At most 1 active request at a time.** If a request is in-flight when canvas changes, the change is queued — generation auto-retriggers on completion.
3. **Latest-request-wins.** Response's requestId must match current latestRequestId to update UI. Stale responses discarded silently.
4. **Prompt/style changes trigger immediately.** No debounce wait when user changes prompt text or style preset — fire generation right away.
5. **Manual generate button bypasses debounce.** User can tap "Generate" anytime.

## Latency Budget — Preview (Target: 4-8 seconds end-to-end)

| Phase | Budget | Notes |
|---|---|---|
| Debounce wait | 1,500ms (fixed) | Prevents request spam during active drawing |
| Client preprocessing | 50ms | JPEG encode at 85% quality + base64 |
| Network upload | 200-500ms | Base64 sketch in JSON body |
| Backend processing | 50ms | Prompt building + schema validation |
| Provider inference | 3,000-6,000ms | Qwen-Image 20B, ~8 steps, ControlNet Union |
| Image download + decode | 200ms | Download from RunPod pod URL |
| **Total** | **5,000-8,300ms** | |

## Input Pipeline Steps

1. Capture canvas snapshot from PencilKit as UIImage
2. Encode to JPEG at 85% quality (canvas capture includes white background)
3. Base64 encode
4. Combine with prompt + style preset modifier
5. Package as JSON with sessionId, requestId, mode, advancedParameters
