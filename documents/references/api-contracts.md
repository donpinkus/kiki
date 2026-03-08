# API Contracts

All endpoints require JWT auth header: `Authorization: Bearer <token>` (except /health).

## POST /v1/generate

Generate an image from a sketch.

### Request
```json
{
  "sessionId": "string (UUID)",
  "requestId": "string (UUID)",
  "mode": "preview" | "refine",
  "prompt": "string | null (optional user prompt)",
  "autoCaption": "string | null (VLM-generated if prompt is empty)",
  "stylePreset": "photoreal" | "anime" | "watercolor" | "storybook" | "fantasy" | "ink" | "neon",
  "adherence": 0.7,        // float 0.0-1.0, default 0.7, maps to ControlNet conditioning scale
  "creativity": 0.5,       // float 0.0-1.0, default 0.5
  "seed": null,            // int | null, null = random
  "aspectRatio": "1:1",    // string, default "1:1"
  "sketchImageBase64": "string (JPEG at 85% quality)",
  "metadata": {
    "canvasWidth": 1024,
    "canvasHeight": 1024,
    "appVersion": "1.0.0",
    "deviceModel": "iPad Pro 13-inch (M4)"
  }
}
```

### Response (200)
```json
{
  "requestId": "string (UUID, echoed back)",
  "status": "completed" | "filtered" | "error",
  "imageUrl": "string | null (signed CDN URL, 7-day expiry)",
  "seed": 42,
  "provider": "fal" | "replicate",
  "latencyMs": 450,
  "mode": "preview" | "refine",
  "contentFilterResult": {
    "flagged": false,
    "categories": []
  }
}
```

### Status Codes
- `200` — Success (check `status` field for "completed", "filtered", or "error")
- `400` — Invalid request (validation failure)
- `401` — Unauthorized (invalid/expired JWT)
- `429` — Rate limited or quota exceeded
- `500` — Internal server error

## POST /v1/cancel

Cancel an in-flight generation request.

### Request
```json
{
  "sessionId": "string (UUID)",
  "requestId": "string (UUID)"
}
```

### Response (200)
```json
{
  "acknowledged": true
}
```

## GET /v1/history

Retrieve generation history for a session.

### Query Parameters
- `sessionId` (required) — UUID
- `limit` (optional, default 50) — int
- `offset` (optional, default 0) — int

### Response (200)
```json
{
  "items": [
    {
      "requestId": "string",
      "mode": "preview" | "refine",
      "prompt": "string | null",
      "autoCaption": "string | null",
      "stylePreset": "string",
      "imageUrl": "string",
      "seed": 42,
      "latencyMs": 450,
      "createdAt": "2026-03-08T12:00:00Z"
    }
  ],
  "total": 100,
  "hasMore": true
}
```

## WSS /v1/generate/stream

WebSocket endpoint for real-time preview generation (sub-second LCM).

### Connection
- URL: `wss://<host>/v1/generate/stream`
- Auth: JWT in `Authorization` header during HTTP upgrade
- Backend proxies to fal.ai's real-time LCM endpoint

### Client → Server
- **Binary frame:** Sketch image (JPEG bytes)
- **Text frame:** JSON with prompt, style, params:
```json
{
  "sessionId": "string",
  "requestId": "string",
  "prompt": "string | null",
  "stylePreset": "string",
  "adherence": 0.7
}
```

### Server → Client
- **Binary frame:** Generated image (JPEG bytes)
- **Text frame:** JSON status/error:
```json
{
  "type": "error" | "filtered" | "status",
  "message": "string",
  "requestId": "string"
}
```

### Behavior
- Client maintains persistent connection during active drawing sessions
- Falls back to REST POST /v1/generate if WebSocket drops
- Backend adds <20ms latency (content safety check is only processing step)
- Heartbeat every 15 seconds to detect stale connections

## GET /health

Health check (no auth required).

### Response (200)
```json
{
  "status": "ok",
  "providers": {
    "fal": "up" | "down",
    "replicate": "up" | "down"
  }
}
```
