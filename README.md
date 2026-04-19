# Kiki

Kiki is an iPad-native sketch-to-image prototype. The user draws on the left side of the canvas and receives a live AI interpretation on the right via a Fastify backend that provisions and relays to a dedicated RunPod FLUX.2-klein server.

Current status: Phase 1 prototype.

## Architecture

- `ios/` contains the SwiftUI app and local Swift packages for canvas, networking, and result display.
- `backend/` contains the Fastify API, WebSocket relay, and per-session pod orchestrator.
- `flux-klein-server/` contains the Python WebSocket server that runs inside the provisioned GPU pod.
- `documents/` contains implementation decisions, provider references, safety requirements, and roadmap material.

For the detailed working guide, read [`CLAUDE.md`](./CLAUDE.md). For agent-oriented onboarding, read [`AGENTS.md`](./AGENTS.md).

## Quick Start

### Backend

```bash
cd backend
npm install
npm run dev
```

Build and test:

```bash
cd backend
npm run build
npm test
```

Environment variables are documented in [`backend/.env.example`](./backend/.env.example). Real RunPod orchestration requires `RUNPOD_API_KEY` and `RUNPOD_SSH_PRIVATE_KEY`.

### iOS

```bash
xcodebuild -scheme Kiki -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' build
xcodebuild -scheme Kiki -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' test
```

Local package checks:

```bash
swift test --package-path ios/Packages/CanvasModule
swift test --package-path ios/Packages/NetworkModule
swift test --package-path ios/Packages/ResultModule
```

### Pod-Side Server Utilities

```bash
python3 flux-klein-server/test_client.py --help
```

## Repository Layout

- `ios/`: iPad app, SwiftUI views, app coordinator, local Swift packages
- `backend/`: Fastify server, relay route, RunPod orchestration
- `flux-klein-server/`: Python image generation server for the pod
- `documents/`: decisions, plans, content safety, provider references
- `scripts/`: supporting setup scripts copied into runtime assets

## Key References

- [`CLAUDE.md`](./CLAUDE.md): current architecture and product constraints
- [`documents/references/content-safety.md`](./documents/references/content-safety.md): App Store and safety requirements
- [`documents/references/provider-config.md`](./documents/references/provider-config.md): RunPod/provider setup notes
- [`documents/decisions.md`](./documents/decisions.md): implementation history and decisions

## Known Limitations

- Backend authentication is still mock-only.
- Fresh sessions can take several minutes to cold start because pod setup and model warmup happen during provisioning.
- Safety/compliance items called out in `CLAUDE.md` and `documents/references/content-safety.md` are not fully implemented yet.
- Some planning docs remain useful context but are partially stale; trust the code and `CLAUDE.md` first.
