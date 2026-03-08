# Error Handling

## Core Rule
NEVER clear the last successful image because of a new failure. The right pane should always show something useful.

## Failure Mode → UX Behavior Matrix

| Failure Mode | Right Pane | User-Facing Indicator | Engineering Behavior |
|---|---|---|---|
| Network timeout | Keep last successful image | Toast: "Connection lost. Retrying..." | Retry up to 3x with exponential backoff (1s, 2s, 4s). Log latency + failure. |
| Provider 5xx | Keep last successful image | Toast: "Connection lost. Retrying..." | Same as timeout. Failover to Replicate if fal.ai errors persist >30 seconds. |
| Rate limit (429) | Keep last successful image | Toast: "You've hit your generation limit. Upgrade for more." | Enforce rate limits client-side before hitting backend. Track daily count. |
| Content filter | Replace with blurred placeholder | Message: "This result was filtered. Try a different prompt." | Log event. Do NOT display filtered image. Do NOT count against quota. |
| Invalid prompt | No change (don't send request) | Inline validation: "Please use a shorter prompt (max 500 characters)." | Reject at API gateway before forwarding to provider. |
| Memory pressure | Keep last image, reduce quality | Toast: "Close other apps for best performance." | Reduce snapshot resolution. Flush image cache proactively. |
| WebSocket drop | Keep last image | No visible indicator (silent reconnect) | Auto-reconnect with exponential backoff. Fallback to REST. Heartbeat every 15s. |
| Auto-caption failure | Use generic style prompt | No visible indicator | Fallback prompt: "A [style] illustration." Skip caption, proceed with generation. |
| Provider timeout (>8s) | Keep preview image visible | Progress bar + "Taking longer than usual..." | Notify user and offer manual retry button. |

## Right Pane State Machine

```
Empty → Generating Preview → Preview Displayed → Refining → Refined Displayed
                                    ↑                              ↓
                                    └──────────────────────────────┘
                                          (new sketch input)

Any state + error → stay in current state, show toast
```

### States

| State | Right Pane Content | Indicator |
|---|---|---|
| Empty | "Start drawing to see your image come to life." | None |
| Generating Preview | Previous image (or placeholder) + shimmer overlay | "Creating preview..." label |
| Preview Displayed | Preview image | None |
| Refining | Preview stays visible + subtle progress ring in corner | "Refining..." label |
| Refined Displayed | Refined image (crossfade 200ms from preview) | None |
| Error | Keep last successful image + non-blocking toast | "Couldn't update. Tap to retry." |

## Client-Side Error Types

```swift
enum GenerationError: Error {
    case networkTimeout
    case serverError(statusCode: Int, message: String)
    case rateLimited(retryAfter: TimeInterval?)
    case contentFiltered(categories: [String])
    case invalidRequest(message: String)
    case cancelled
    case quotaExceeded(remaining: Int, resetAt: Date)
}
```

## Toast Behavior
- Non-blocking: appears at bottom of right pane, does not cover the image
- Auto-dismiss after 4 seconds
- Tap to dismiss immediately
- Only one toast visible at a time (newest replaces oldest)
- Retry toast has a "Tap to retry" action
