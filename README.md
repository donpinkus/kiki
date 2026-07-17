# Kiki

Kiki is an iPad-native sketch-to-image prototype. The user draws on the left side of the canvas and receives a live AI interpretation on the right via a Fastify backend that relays canvas frames to fal.ai's hosted FLUX.2-klein realtime model. (A self-hosted image path on Lambda Cloud H100s is available as a dev toggle via `IMAGE_PROVIDER=lambda`; the LTX video idle-state animation is archived pending a Lambda port — see `archive/video-ltx/`.)

Current status: Phase 1 prototype.

## Architecture

- `ios/` contains the SwiftUI app and local Swift packages for canvas, networking, and result display.
- `backend/` contains the Fastify API, WebSocket relay, per-session pod orchestrator, and a Postgres-backed account store (user accounts + monthly fal-spend ledger).
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

Environment vars in two places:
- **Production** (Railway-hosted backend) — values live on Railway. Template is [`backend/.env.example`](./backend/.env.example); the team has current values set already.
- **Local scripts** — read from `<repo-root>/.env.local` (gitignored): `FAL_KEY`, `LAMBDA_API_KEY`, optional `SENTRY_DSN`. See `backend/scripts/README.md`.

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

### Image-Server Utilities

```bash
python3 model-servers/dev/image_client.py --help
```

## Repository Layout

- `ios/`: iPad app, SwiftUI views, app coordinator, local Swift packages
- `backend/`: Fastify server, fal.ai image relay (`modules/fal/`), Lambda Cloud dev path (`modules/lambda/`)
- `model-servers/`: Python image server (FLUX.2-klein), served on Lambda Cloud
- `archive/`: removed-but-reusable code (LTX video system for the planned Lambda port)
- `documents/`: decisions, plans, content safety, provider references
- `backend/scripts/`: deploy + Lambda Cloud tooling

## Key References

- [`CLAUDE.md`](./CLAUDE.md): current architecture and product constraints
- [`documents/references/content-safety.md`](./documents/references/content-safety.md): App Store and safety requirements
- [`documents/references/provider-config.md`](./documents/references/provider-config.md): provider architecture (fal + Lambda), billing, costs
- [`documents/decisions.md`](./documents/decisions.md): implementation history and decisions

## Known Limitations

- Auth is Sign in with Apple → JWT, with durable accounts in Postgres. The Apple in-app *subscription purchase* (StoreKit 2) is built but not yet live in App Store Connect — unsubscribed users hit a $10/month fal-spend cap; flagged test accounts are unlimited.
- The live (fal.ai) image path reaches its first frame in ~1.5s when the pool is warm (a keep-warm pinger maintains this); the Lambda dev path cold-starts in ~3 min when its instance isn't up.
- Safety/compliance items called out in `CLAUDE.md` and `documents/references/content-safety.md` are not fully implemented yet.
- Some planning docs remain useful context but are partially stale; trust the code and `CLAUDE.md` first.
