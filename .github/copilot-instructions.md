# Copilot Instructions For Kiki

Read [`../CLAUDE.md`](../CLAUDE.md) first. It is the primary source of truth for architecture constraints and banned alternatives.

## What This Repo Is

Kiki is an iPad sketch-to-image app:
- SwiftUI iPad client in `ios/`
- Fastify backend and RunPod orchestrator in `backend/`
- Python FLUX.2-klein pod server in `flux-klein-server/`

## Working Priorities

- Preserve canvas responsiveness above all else.
- Never blank the result pane after a successful image exists.
- Do not move secrets or provider calls onto the client.
- Treat content safety and App Store compliance work as release-critical.

## Repo Guidance

- Prefer `rg` for search.
- Preserve the existing SwiftUI + SwiftData + local-package structure on iOS.
- Preserve the existing Fastify + WebSocket relay approach on the backend unless explicitly asked to redesign it.
- If docs conflict, trust code plus `CLAUDE.md`.

## Useful Entry Points

- `ios/Kiki/App/AppCoordinator.swift`
- `ios/Kiki/Views/DrawingView.swift`
- `backend/src/routes/stream.ts`
- `backend/src/modules/orchestrator/orchestrator.ts`

## Important Note

[`PRD.md`](../PRD.md) and [`TECHNICAL_ARCHITECTURE.md`](../TECHNICAL_ARCHITECTURE.md) are partially stale context docs. Use them for intent, not as the final word on current implementation.
