# Kiki

Kiki is an iPad-native sketch-to-image prototype. The user draws on the left side of the canvas and receives a live AI interpretation on the right via a Fastify backend that relays canvas frames to fal.ai's hosted FLUX.2-klein realtime model. (A per-session RunPod FLUX.2-klein path remains as a dormant, revertable fallback via `IMAGE_PROVIDER=runpod`; the LTX video idle-state animation still runs on RunPod.)

Current status: Phase 1 prototype.

## Architecture

- `ios/` contains the SwiftUI app and local Swift packages for canvas, networking, and result display.
- `backend/` contains the Fastify API, WebSocket relay, and per-session pod orchestrator.
- `model-servers/` contains the Python WebSocket server that runs inside the provisioned GPU pod.
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

Environment vars in two places:
- **Production** (Railway-hosted backend) — values live on Railway. Template is [`backend/.env.example`](./backend/.env.example); the team has current values set already.
- **Local scripts** (`npm run deploy`, `npm run launch-test-pod`, etc.) — read from `<repo-root>/.env.local` (gitignored). Minimum set: `RUNPOD_API_KEY`, `NETWORK_VOLUMES_BY_DC`, `NETWORK_VOLUMES_BY_DC_VIDEO`. See pod-operations.md "Global prerequisites" for the full list.

Pods themselves boot from stock `runpod/pytorch` and read app code off pre-populated network volumes; see `documents/references/provider-config.md`.

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
python3 model-servers/dev/image_client.py --help
```

## Repository Layout

- `ios/`: iPad app, SwiftUI views, app coordinator, local Swift packages
- `backend/`: Fastify server, fal.ai image relay (`modules/fal/`) + RunPod orchestration (video + dormant image fallback)
- `model-servers/`: Python WebSocket servers for RunPod pods — video idle-state (live) and the dormant image fallback
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
- The live (fal.ai) image path reaches its first frame in ~1.5s. The dormant RunPod image fallback and the RunPod video idle-state pod still cold-start in ~1–3 min (pod setup + model warmup during provisioning).
- Safety/compliance items called out in `CLAUDE.md` and `documents/references/content-safety.md` are not fully implemented yet.
- Some planning docs remain useful context but are partially stale; trust the code and `CLAUDE.md` first.
