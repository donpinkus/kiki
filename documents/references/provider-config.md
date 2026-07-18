# Provider Configuration

## Current Stack

> **History:** the image path moved to fal.ai on 2026-06-06; the entire
> RunPod pod-orchestration system (dormant image fallback + LTX video
> idle-state pods) was removed on 2026-07-17; and production switched to
> `IMAGE_PROVIDER=auto` (own H100 pool with fal fallback) on 2026-07-18.
> Video is planned to return on Lambda Cloud — the serving code is archived
> in `archive/video-ltx/`. See `documents/decisions.md`.

Each user session is a WebSocket relay (`backend/src/routes/stream.ts`) from
the iPad to an image provider, selected by `IMAGE_PROVIDER`:

- **auto (production, since 2026-07-18)** — per-session resolution: relay to
  the least-loaded Lambda H100 pool instance when one is assignable, else
  serve fal; auto-resolved sessions degrade to fal mid-session if their
  instance dies (frames keep flowing). Explicit `?imageProvider=` test-account
  overrides never silently switch (A/B purity).
- **fal (config default; auto-mode's fallback)** — fal.ai hosted
  `fal-ai/flux-2/klein/realtime` over a per-session msgpack WebSocket
  (server-side `Authorization: Key $FAL_KEY`). ~1.5s to first frame,
  ~250ms/frame at 3 steps. No pods, no provisioning: the relay lives and dies
  with the WS connection.
- **lambda (force our own servers — dev/test toggle)** — our own image server
  (`model-servers/image/server.py`, FLUX.2-klein-9B-KV) on the Lambda Cloud
  H100 pool (`backend/src/modules/lambda/devPool.ts` — evolved from the
  single-instance dev pool into the production fleet manager: `kiki-serve-*`
  instances, least-loaded assignment, health probes with 3-strike replace,
  pressure autoscale between `LAMBDA_POOL_MIN`..`MAX`, 30-min idle
  scale-down), or a static `LAMBDA_IMAGE_URL` instance. See
  `documents/plans/lambda-image-provider.md` + `backend/scripts/lambda/README.md`.

There is no server-side session registry: state transitions
(`connecting`/`ready`) are emitted inline on the WS connection, and Postgres
holds the only durable per-user state (accounts + spend ledger).

## fal.ai image path (live)

- Endpoint `wss://fal.run/fal-ai/flux-2/klein/realtime`, msgpack messages, server-side `Authorization: Key $FAL_KEY` (no secret on the client — CLAUDE.md #3). Code: `backend/src/modules/fal/falImageRelay.ts` (implements `ImageRelay`) + the fal branch in `routes/stream.ts`.
- Input msg: `{image_url:"data:image/jpeg;base64,…", prompt, num_inference_steps, schedule_mu, output_feedback_strength, image_size, seed, sync_mode:true}`. Output: `{images:[{content:<jpeg bytes>, content_type, …}], seed}`.
- fal emits no `queueEmpty`; the relay synthesizes a `frame_meta{queueEmpty}` before each frame (mirroring `model-servers/image/server.py`) — kept so the future idle-state video trigger can key off it unchanged.
- fal force-closes an idle realtime socket after **~30s** of no input ("reconnect when needed"); the relay reconnects lazily on the next stroke.
- **Billing = time a warm runner is ATTACHED to your open connection** (~$0.00194/s, ~2s floor per open). The cold spin-up / enqueue wait is NOT billed (no runner attached yet); an idle-open *warm* socket IS billed. Verified against both the 2026-06-06 controlled runs and the 2026-07-14 dashboard readback.
- **Cost levers** (in `falImageRelay.ts`): **lazy-connect** — no socket until the first stroke, so opening a drawing without drawing costs $0; **`FAL_IDLE_CLOSE_MS`** (Railway env, set to `2000`) — close the WS N ms after the last frame and reopen on the next stroke, so idle bills ~N seconds instead of ~30. Set `0` to disable.
- **Keep-warm:** fal's marketplace pool scales to zero (warmth lapses <15 min idle; cold spin-up ~1.7–3.5 min during which fal silently drops inputs). `backend/src/modules/fal/falWarmer.ts` pings every 90s by default (the 30s tick granularity stretches gaps to interval+30s, and 150s is the measured cold boundary — so 120s ping intervals are already borderline); runtime dial lives in the `admin_config.fal_warmer` Postgres row, edited live from Kiki Insights → Ops. Runs under `IMAGE_PROVIDER=auto` too (a cold fal pool means dropped frames exactly when the H100 pool degrades sessions onto it).
- **Spend cap:** unsubscribed users get `FREE_TIER_FAL_USD` (=$10) of drawing spend per UTC month, metered from relay open-time (`backend/src/modules/falBudget/`), enforced at session start + mid-session in `routes/stream.ts`. Test accounts + active subscribers exempt.

## Lambda Cloud image path (production pool under `auto`)

- Raw H100 VMs, no provider orchestration APIs on the serving path. Per-region
  persistent filesystem (`kiki-image-<region>`) holds weights + venv +
  `boot.sh`, populated by `backend/scripts/lambda/setup-lambda.ts`. NFS
  inductor/triton cache makes restarts/scale-ups ready in ~90s.
- Auth seam: `KIKI_WS_TOKEN` (HMAC of instance id) — see
  `model-servers/image/server.py`. Raw VMs have guessable IPs, unlike a proxy.
- TLS: instances serve wss with a shared self-signed cert; the backend pins it
  via `LAMBDA_TLS_CA_B64`.
- Pool (`devPool.ts` — name is historical): `kiki-serve-*` instances adopted
  across redeploys by name prefix + HMAC token; least-loaded stream
  assignment; 60s health-probe tick (3 strikes → terminate + replace);
  pressure autoscale (`LAMBDA_POOL_TARGET_STREAMS`=4 per instance,
  `LAMBDA_POOL_MIN`..`MAX`); 30-min idle scale-down.
- Metering: $0.001/lambda-frame into the same `monthly_usage` ledger as fal
  (one unified free tier).
- H100 = Hopper → BF16 only (no NVFP4; that needs Blackwell).

## Required env vars (Railway)

Set via `railway variable set "KEY=value"` (singular subcommand, runs in `backend/` after `railway link`) or the Railway dashboard:

| Env | Source | Purpose |
|---|---|---|
| `IMAGE_PROVIDER` | `auto` (production), `fal` (code default), or `lambda` | Live image path selector |
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
| `LAMBDA_API_KEY` / `LAMBDA_DEV_POOL_ENABLED` / `LAMBDA_REGION` / `LAMBDA_INSTANCE_TYPE` / `LAMBDA_IMAGE_URL` | Lambda Cloud | H100 pool / static-instance image path |
| `LAMBDA_POOL_MIN` / `LAMBDA_POOL_MAX` / `LAMBDA_POOL_TARGET_STREAMS` | defaults in `config/index.ts` | Pool autoscale bounds + per-instance stream target (4) |
| `LAMBDA_TLS_CA_B64` | base64 of the fleet cert | Pin the pool instances' self-signed TLS cert |
| `FAL_WARMER_ENABLED` / `FAL_WARMER_INTERVAL_MS` / `FAL_WARMER_OFF_*` | defaults in `config/index.ts` | Seed values for the warmer's `admin_config.fal_warmer` row (live dial in Insights → Ops) |

## Operations

```bash
railway logs    # tail backend activity
```

Deploy: `cd backend && npm run deploy` (plain `railway up` with Sentry
`phase:deploying` markers).

### Cost

- fal: billed per warm-runner-attached second (~$0.00194/s); warmer ~$1/day.
- Lambda pool: H100 on-demand hourly while up (internal sources quote
  $2.49–$4.29/hr depending on SKU — `scripts/lambda/README.md` says $3.29/hr
  for sxm5; reconcile against the Lambda pricing page before cost modeling);
  idle instances scale down after 30 min.
- Railway backend + Postgres + Insights: ~$10/month flat.
