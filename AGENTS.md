# AGENTS.md

Kiki is an iPad-native sketch-to-image app with:
- `ios/`: SwiftUI client
- `backend/`: Fastify relay and RunPod orchestrator
- `flux-klein-server/`: Python pod-side FLUX.2-klein server

## Source Of Truth

Read [`CLAUDE.md`](./CLAUDE.md) first. It is the primary repo-specific instruction file and wins over this file if they ever diverge.

Use this file as a thin entrypoint only. Use [`README.md`](./README.md) for human onboarding and local setup.

## Hard Constraints

- Preserve canvas responsiveness. Do not couple drawing latency to network or generation work.
- Never blank the result pane after a successful image exists.
- Do not move provider secrets or direct inference calls onto the client.
- Treat content safety and App Store compliance work as release-critical.
- Avoid architectural redesigns that conflict with `CLAUDE.md` unless explicitly requested.

## Useful Entry Points

- `ios/Kiki/App/AppCoordinator.swift`
- `ios/Kiki/Views/DrawingView.swift`
- `backend/src/routes/stream.ts`
- `backend/src/modules/orchestrator/orchestrator.ts`

## Working Notes

- Prefer `rg` for search.
- Trust code plus `CLAUDE.md` over older planning docs.
- Keep repo guidance thin here; do not duplicate large sections from `CLAUDE.md`.
