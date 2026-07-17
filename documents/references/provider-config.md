# Provider Configuration

## Current Stack

> **History:** the image path moved to fal.ai on 2026-06-06, and the entire
> RunPod pod-orchestration system (dormant image fallback + LTX video
> idle-state pods) was removed on 2026-07-17. Video is planned to return on
> Lambda Cloud — the serving code is archived in `archive/video-ltx/`. See
> `documents/decisions.md` for both entries.

Each user session is a WebSocket relay (`backend/src/routes/stream.ts`) from
the iPad to one of two image providers, selected by `IMAGE_PROVIDER`:

- **fal (production, config default)** — fal.ai hosted
  `fal-ai/flux-2/klein/realtime` over a per-session msgpack WebSocket
  (server-side `Authorization: Key $FAL_KEY`). ~1.5s to first frame,
  ~250ms/frame at 3 steps. No pods, no provisioning: the relay lives and dies
  with the WS connection.
- **lambda (dev toggle, test accounts only)** — our own image server
  (`model-servers/image/server.py`, FLUX.2-klein BF16) on a Lambda Cloud H100.
  Either a static `LAMBDA_IMAGE_URL` instance or the single-instance dev pool
  (`backend/src/modules/lambda/devPool.ts`, 30-min idle reap). See
  `documents/plans/lambda-image-provider.md` + `backend/scripts/lambda/README.md`.

There is no server-side session registry: state transitions
(`connecting`/`ready`) are emitted inline on the WS connection, and Postgres
holds the only durable per-user state (accounts + fal spend ledger).

## fal.ai image path (live)

- Endpoint `wss://fal.run/fal-ai/flux-2/klein/realtime`, msgpack messages, server-side `Authorization: Key $FAL_KEY` (no secret on the client — CLAUDE.md #3). Code: `backend/src/modules/fal/falImageRelay.ts` (implements `ImageRelay`) + the fal branch in `routes/stream.ts`.
- Input msg: `{image_url:"data:image/jpeg;base64,…", prompt, num_inference_steps, schedule_mu, output_feedback_strength, image_size, seed, sync_mode:true}`. Output: `{images:[{content:<jpeg bytes>, content_type, …}], seed}`.
- fal emits no `queueEmpty`; the relay synthesizes a `frame_meta{queueEmpty}` before each frame (mirroring `model-servers/image/server.py`) — kept so the future idle-state video trigger can key off it unchanged.
- fal force-closes an idle realtime socket after **~30s** of no input ("reconnect when needed"); the relay reconnects lazily on the next stroke.
- **Billing = time a warm runner is ATTACHED to your open connection** (~$0.00194/s, ~2s floor per open). The cold spin-up / enqueue wait is NOT billed (no runner attached yet); an idle-open *warm* socket IS billed. Verified against both the 2026-06-06 controlled runs and the 2026-07-14 dashboard readback.
- **Cost levers** (in `falImageRelay.ts`): **lazy-connect** — no socket until the first stroke, so opening a drawing without drawing costs $0; **`FAL_IDLE_CLOSE_MS`** (Railway env, set to `2000`) — close the WS N ms after the last frame and reopen on the next stroke, so idle bills ~N seconds instead of ~30. Set `0` to disable.
- **Keep-warm:** fal's marketplace pool scales to zero (warmth lapses <15 min idle; cold spin-up ~1.7–3.5 min during which fal silently drops inputs). `backend/src/modules/fal/falWarmer.ts` pings every 2 min; runtime dial lives in the `admin_config.fal_warmer` Postgres row, edited live from Kiki Insights → Ops. Don't raise the interval above 120s — warmth collapses at 150s gaps (binary-searched 2026-07-14).
- **Spend cap:** unsubscribed users get `FREE_TIER_FAL_USD` (=$10) of drawing spend per UTC month, metered from relay open-time (`backend/src/modules/falBudget/`), enforced at session start + mid-session in `routes/stream.ts`. Test accounts + active subscribers exempt.

## Lambda Cloud image path (dev)

- Raw H100 VMs, no provider orchestration APIs on the serving path. Per-region
  persistent filesystem (`kiki-image-<region>`) holds weights + venv +
  `boot.sh`, populated by `backend/scripts/lambda/setup-lambda.ts`.
- Auth seam: `KIKI_WS_TOKEN` (HMAC of instance id) — see
  `model-servers/image/server.py`. Raw VMs have guessable IPs, unlike a proxy.
- Dev pool: at most one `kiki-serve` instance, launched on demand
  (`POST /v1/dev/lambda/ensure` or app login), idle-reaped after 30 min,
  re-adopted across backend redeploys by name prefix + deterministic token.
- H100 = Hopper → BF16 only (no NVFP4; that needs Blackwell).

## Required env vars (Railway)

Set via `railway variable set "KEY=value"` (singular subcommand, runs in `backend/` after `railway link`) or the Railway dashboard:

| Env | Source | Purpose |
|---|---|---|
| `IMAGE_PROVIDER` | `fal` (default) or `lambda` | Live image path selector |
| `FAL_KEY` | fal.ai dashboard | fal realtime WS auth. Required when provider=fal. |
| `FAL_IDLE_CLOSE_MS` | `2000` | Idle-close cost lever (see above) |
| `DATABASE_URL` | Railway Postgres addon | Accounts + fal spend ledger. Required. |
| `JWT_ACCESS_SECRET` | ≥32 byte hex (`openssl rand -hex 32`) | HS256 secret for access tokens. Required, must differ from refresh. |
| `JWT_REFRESH_SECRET` | ≥32 byte hex (`openssl rand -hex 32`) | HS256 secret for refresh tokens. Required, must differ from access. |
| `APPLE_BUNDLE_ID` | iOS bundle ID | Apple identity token audience. Required. |
| `APPLE_APP_APPLE_ID` | App Store Connect numeric app id | Production StoreKit verification (sandbox works without it) |
| `AUTH_REQUIRED` | `true` | Reject unauthenticated connections. Production must always be `true`. |
| `FREE_TIER_FAL_USD` | default `10` | Monthly free fal spend per unsubscribed user |
| `SENTRY_DSN` | Sentry project | Backend errors + logs |
| `INSIGHTS_URL` / `INSIGHTS_INGEST_KEY` | Insights service | Event + frame-capture mirroring to Kiki Insights |
| `SESSION_CAPTURE_ENABLED` | default `true` | Admin session-replay frame capture kill switch |
| `LAMBDA_API_KEY` / `LAMBDA_DEV_POOL_ENABLED` / `LAMBDA_REGION` / `LAMBDA_INSTANCE_TYPE` / `LAMBDA_IMAGE_URL` | Lambda Cloud | Dev image path (optional) |

## Operations

```bash
railway logs    # tail backend activity
```

Deploy: `cd backend && npm run deploy` (plain `railway up` with Sentry
`phase:deploying` markers).

### Cost

- fal: billed per warm-runner-attached second (~$0.00194/s); warmer ~$1/day.
- Lambda dev pool: H100 on-demand (~$2.49/hr) while up; idle-reaped after 30 min.
- Railway backend + Postgres + Insights: ~$10/month flat.
