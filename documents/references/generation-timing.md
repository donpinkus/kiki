# Generation Timing

## Debounce Configuration

| Timer | Duration | Triggers | Model |
|---|---|---|---|
| Preview | 300ms of drawing inactivity | SD 1.5 + LCM-LoRA via fal.ai | 512x512, 4-6 inference steps |
| Refine | 1200ms of drawing inactivity | SDXL + ControlNet Scribble via fal.ai | 1024x1024, 20-30 steps |

## Scheduling Rules

1. **New strokes reset BOTH timers.** Any canvas change event restarts preview and refine countdown.
2. **New strokes cancel ALL in-flight requests.** When drawing resumes, cancel preview and refine via Task.cancel() + POST /v1/cancel.
3. **At most 1 active preview + 1 active refine at any time.** New request for same mode obsoletes the prior one.
4. **Latest-request-wins.** Response's requestId must match current latestRequestId to update UI. Stale responses discarded silently.
5. **Prompt/style changes trigger immediately.** No debounce wait when user changes prompt text or style preset — fire generation right away.
6. **Preview success does NOT cancel in-flight refine** for the same sketch. Both can complete.
7. **Manual mode skips debounce.** In manual mode, generation only fires on explicit "Generate" button tap.

## Latency Budget — Preview (Target: 1 second end-to-end)

| Phase | Budget | Notes |
|---|---|---|
| Debounce wait | 300ms (fixed) | Could reduce to 200ms; increases cancelled request rate |
| Client preprocessing | 50ms | vImage hardware acceleration, pre-allocate output buffers |
| Auto-caption (on-device) | 150ms | Skip if user typed a prompt |
| Network round-trip | 100ms | WebSocket eliminates HTTP overhead |
| Backend processing | 30ms | Quota (1ms) + prompt filter (5ms) + routing (1ms) + NSFW check (~20ms) |
| Provider inference | 300ms | fal.ai LCM at 4 steps, near-optimal |
| Image download + decode | 70ms | CDN-cached, JPEG decode on background thread |
| **Total** | **1,000ms** | |

## Latency Budget — Refine (Target: 3-5 seconds)

| Phase | Budget | Notes |
|---|---|---|
| Debounce wait | 1,200ms (fixed) | |
| Client preprocessing | 80ms | Higher resolution (1024x1024) |
| Auto-caption | 150ms | Same as preview |
| Network round-trip | 100ms | REST endpoint (not WebSocket) |
| Backend processing | 30ms | Same as preview |
| Provider inference | 2,000-4,000ms | SDXL + ControlNet at 20-30 steps |
| Image download + decode | 100ms | Larger image |
| **Total** | **3,660-5,660ms** | |

## Fallback Behavior

| Metric | Target | Acceptable | Fallback |
|---|---|---|---|
| Preview latency | <1s | <2s | Switch to 2-step LCM or reduce to 384x384 |
| Refine latency | 2-5s | <8s | Show progress bar. If >8s, offer manual retry. |
| Auto-caption | <200ms | <500ms | Use server-side caption with generation request |

## Preview vs. Refine Comparison

| Attribute | Preview | Refine |
|---|---|---|
| Purpose | Fast early feedback | High-quality final output |
| Model | SD 1.5 + LCM-LoRA | SDXL + ControlNet Scribble |
| Resolution | 512x512 | 1024x1024 |
| Steps | 4-6 | 20-30 |
| Target latency | <1 second | 2-5 seconds |
| Cost per image | ~$0.003 | ~$0.02 |
| Quality | Noisy but compositionally useful | Clean, detailed, publishable |
| Connection | WebSocket (preferred) or REST | REST only |

## Input Pipeline Steps

1. Capture canvas snapshot from PencilKit as UIImage
2. Flatten to high-contrast monochrome (maximize edge signal for ControlNet)
3. Crop to content bounds with 10% padding
4. Resize: 512x512 (preview) or 1024x1024 (refine)
5. If no user prompt: run auto-captioning VLM
6. Combine caption with style preset template
7. Package as JSON with sessionId, requestId, mode, params
