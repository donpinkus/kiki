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

Deploy (backend + pod app code in one command):

```bash
cd backend
npm run deploy
```

For the full decision tree of pod operations — deploy, iterate on pod code, run experiments, SSH, terminate — see [`documents/references/pod-operations.md`](./documents/references/pod-operations.md).

Environment variables are documented in [`backend/.env.example`](./backend/.env.example). Real RunPod orchestration requires `RUNPOD_API_KEY`, `NETWORK_VOLUMES_BY_DC` (pre-populated image-pod weight/code volumes), and `NETWORK_VOLUMES_BY_DC_VIDEO` (video-pod volumes). Pods boot from stock `runpod/pytorch` and read app code off these volumes; see `documents/references/provider-config.md`.

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
- `backend/scripts/`: operational one-off scripts (network volume population, capacity probes)

## Key References

- [`CLAUDE.md`](./CLAUDE.md): current architecture and product constraints
- [`documents/references/pod-operations.md`](./documents/references/pod-operations.md): canonical decision tree for deploying / iterating / experimenting / SSHing / terminating pods (read this for any operations work)
- [`documents/references/content-safety.md`](./documents/references/content-safety.md): App Store and safety requirements
- [`documents/references/provider-config.md`](./documents/references/provider-config.md): orchestration architecture, network volumes, costs
- [`documents/decisions.md`](./documents/decisions.md): implementation history and decisions

## Known Limitations

- Backend authentication is still mock-only.
- Fresh sessions can take several minutes to cold start because pod setup and model warmup happen during provisioning.
- Safety/compliance items called out in `CLAUDE.md` and `documents/references/content-safety.md` are not fully implemented yet.
- Some planning docs remain useful context but are partially stale; trust the code and `CLAUDE.md` first.
