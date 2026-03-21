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
  "stylePreset": "photoreal" | "anime" | "watercolor" | "storybook" | "fantasy" | "ink" | "neon",
  "sketchImageBase64": "string (JPEG at 85% quality)",
  "advancedParameters": {
    "controlNetStrength": 0.8,
    "controlNetEndPercent": 0.8,
    "cfgScale": 1.0,
    "steps": 8,
    "denoise": 0.65,
    "auraFlowShift": 1.73,
    "loraStrength": 0.8,
    "negativePrompt": "string | null",
    "seed": null
  }
}
```

### Response (200)
```json
{
  "requestId": "string (UUID, echoed back)",
  "status": "completed" | "filtered" | "error",
  "imageUrl": "string | null (ComfyUI output URL)",
  "inputImageUrl": "string | null (uploaded sketch URL)",
  "lineartImageUrl": "string | null (lineart preprocessor output URL)",
  "seed": 42,
  "provider": "comfyui",
  "latencyMs": 4500,
  "mode": "preview" | "refine",
  "workflow": { }
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
      "latencyMs": 4500,
      "createdAt": "2026-03-08T12:00:00Z"
    }
  ],
  "total": 100,
  "hasMore": true
}
```

## GET /health

Health check (no auth required).

### Response (200)
```json
{
  "status": "ok",
  "timestamp": "2026-03-08T12:00:00Z"
}
```
