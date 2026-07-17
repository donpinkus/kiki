# Cleanup 2026-07-17 — read me, then delete me

Overnight autonomous cleanup per your request. Everything is committed on
`main` (local, not pushed) in five commits, each independently revertable:

| Commit | What |
|---|---|
| `0805dfe` | PostHog removed (backend + iOS + docs); Insights is the analytics store |
| `d9e3c43` | LTX video server + docs archived to `archive/video-ltx/` |
| `b0fede2` | **RunPod orchestration removed** — orchestrator, Redis, rate limiter, ops routes, scripts, workflows; stream.ts rewritten for fal + Lambda |
| `3b55ca5` | All docs updated (CLAUDE.md, provider-config, decisions, removed-features, README, plans moved to completed/) |
| (last) | This note + final sweeps |

Verified green after each stage: backend `build` + `lint` + `test` (5/5),
analytics service build, iOS simulator build (after the PostHog/iOS changes).

## Actions only you can do (cost savings + hygiene)

1. **Railway — delete unused env vars** on the backend service:
   `RUNPOD_API_KEY`, `RUNPOD_REGISTRY_AUTH_ID`, `NETWORK_VOLUMES_BY_DC`,
   `NETWORK_VOLUMES_BY_DC_VIDEO`, `REDIS_URL`, `VIDEO_POD_ENABLED`,
   `ONDEMAND_FALLBACK_ENABLED`, `ONDEMAND_ONLY_MODE`,
   `PREEMPTION_REPLACEMENT_ENABLED`, `MAX_SESSION_REPLACEMENTS`,
   `RECONCILE_INTERVAL_MS`, `RECONCILE_MIN_AGE_SEC`, `POD_BOOT_*`,
   `COST_MONITOR_INTERVAL_MS`, `COST_ALERT_*`, `COST_POD_LOG_WEBHOOK_URL`,
   `OPS_API_KEY`, `MAX_CONCURRENT_PROVISIONS`, `PUBLIC_KEY`, `FLUX_IMAGE`,
   `RUNPOD_GHCR_AUTH_ID`, `SENTRY_DSN_POD` (backend no longer forwards it).
2. **Railway — remove the Redis addon** (nothing reads it anymore).
3. **RunPod — destroy the 11 network volumes** (5 image + 6 video ≈ **$49/mo**)
   and revoke the API key when done. Volume IDs are in
   `documents/removed-features.md` git history / the old provider-config.
4. **GitHub — delete the `RUNPOD_API_KEY` Actions secret** (stop-pods workflow
   is gone).
5. **PostHog** — project 389365 holds historical events; close the account
   whenever that history stops being useful. You can also drop the
   `POSTHOG_PERSONAL_API_KEY` / `POSTHOG_PROJECT_ID` lines from root
   `.env.local` (I don't edit your secrets file).

## Deliberate keeps (not oversights)

- **iOS video render path + Settings video knobs** (`VideoEvent`,
  `ResultState.videoStreaming/.videoLooping`, `LoopingVideoView`, video
  frames/prompt-suffix/profiling settings) — the client half of the planned
  Lambda video revival. Inert until a backend sends `video_*` messages again.
- **fal relay's synthetic `frame_meta{queueEmpty}`** — same reason.
- **`fal-spike/`** — protocol verification reference cited by falImageRelay.
- **`model-servers/shared/sentry_init.py`** still reads `RUNPOD_POD_ID` /
  `KIKI_USER_ID` env (harmless no-ops on Lambda).

## Flags / things I wasn't sure about

- **`kiki-pod` Sentry project is now dormant**: Lambda instances never set
  `SENTRY_DSN_POD` (boot.sh doesn't export it). If you want image-server logs
  in Sentry, wire it into `setup-lambda.ts`'s boot.sh. Noted in CLAUDE.md.
- **Provision rate limiting is gone with the pods.** The only abuse bound on
  the fal path is the $10/mo spend cap (which is per-user, post-auth). If you
  want a connection-frequency limit before beta, it needs a new (Postgres or
  in-memory) implementation.
- **iOS "Session paused" / `state:'terminated'` handling never triggers now**
  (it was fed by the pod idle reaper). Left in place; harmless.
- **`documents/ideas/flux-klein-capabilities.md`** references pod-era
  capabilities in places — I left it untouched (idea notebook, not ops doc).
- **Concurrent session note:** while I worked, another Claude session
  committed `f05a87e` (generation→canvas round-trip methodology doc) at
  01:20; it incidentally picked up my staged plan-file moves. No conflict —
  just so the log doesn't surprise you.

## Where things went

- Archived (for the Lambda video port): `archive/video-ltx/` — pipeline,
  server, protocol client, LTX config extract, video requirements, design
  docs, perf investigations, porting notes. Start at its README.
- Historical plans: `documents/plans/completed/` (workstreams 1–8,
  scale-to-100, phase-1).
- Removal records: `documents/decisions.md` (2026-07-17) and
  `documents/removed-features.md`.
