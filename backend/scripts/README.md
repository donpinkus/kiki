# `backend/scripts/`

Operational scripts for the RunPod side of the stack. All run from `backend/`
via `npx tsx scripts/<name>.ts`.

## Operating these in production

If you're trying to deploy backend or pod code, iterate on a pod, or run
test/experiment pods — read **`documents/references/pod-operations.md`**
first. It's the canonical decision tree and uses the scripts below as its
implementation. The notes here are reference detail for the scripts
themselves, not a deploy runbook.

## Naming convention

Six families, distinguished by the verb:

| Prefix         | Purpose                                                   | Mutates state? | Costs $?   |
| -------------- | --------------------------------------------------------- | -------------- | ---------- |
| `populate-*`   | First-time provisioning of a volume                       | yes            | yes        |
| `sync-*`       | Push code/dep updates to a volume                         | yes            | yes        |
| `deploy*`      | One-shot orchestration: sync-all + railway up             | yes            | yes        |
| `launch-*` / `terminate-*` / `list-*` | Test pod lifecycle (`kiki-vtest-*` prefix; reaper-invisible) | yes / yes / no | yes (~$3/hr) / no / no |
| `probe-*`      | Measure RunPod *behavior* over time                       | no             | yes        |
| `check-*` / `debug-*` | Read-only point-in-time status / one-off investigation | no             | usually no |

When adding a new script, pick the prefix that matches the verb you'd use to
describe it. `probe-*` and `check-*` differ in that probes spin up real pods
to observe RunPod's behavior under conditions; checks read existing telemetry
or APIs.

## Scripts

### Volume management (`populate-*`, `sync-*`)

- **`populate-volume.ts`** — First-time setup of a network volume. Spawns a
  5090 (image volume) or H100 SXM (video volume), downloads weights into
  `/workspace/huggingface/`, then terminates. Run once per DC volume at
  provisioning time. Pass `--kind image` or `--kind video`. Image: ~15 min,
  ~$0.20. Video: ~30 min, ~$1 (also requires `HF_TOKEN` for Gemma).

- **`sync-flux-app.ts`** — Push updates to `flux-klein-server/*.py` and
  `requirements.txt`. Spawns a cheap pod, rsyncs files into `/workspace/app/`,
  pip-installs into `/workspace/venv/`, writes `/workspace/app/.version.json`
  with the local git SHA, terminates. Run per DC after every code change to
  the FLUX server. ~5–10 min, ~$0.10. Usually invoked indirectly via
  `npm run sync-all` or `npm run deploy`, not directly.

- **`sync-all-dcs.ts`** — Fans `sync-flux-app.ts` out to every DC in
  `NETWORK_VOLUMES_BY_DC` + `NETWORK_VOLUMES_BY_DC_VIDEO` in parallel.
  Per-DC stdout captured to `/tmp/sync-all-<DC>.log`. Aborts non-zero if any
  DC fails. Exposed as `npm run sync-all`. ~5–10 min total (slowest DC
  dominates).

### Deploy orchestration (`deploy*`)

- **`deploy.ts`** — Single-command deploy. Reads `backend/.flux-app-version`,
  diffs against the current `flux-klein-server/` tree hash, runs `sync-all-dcs`
  if changed, then runs `railway up`. Exposed as `npm run deploy`. This is the
  canonical deploy path; use it instead of running sync + railway separately.

### Test pod lifecycle (`launch-*`, `terminate-*`, `list-*`)

- **`launch-test-pod.ts`** — Spawns a video test pod (`kiki-vtest-<hex>`
  prefix, invisible to the orchestrator's reaper). Always passes `PUBLIC_KEY`
  to force the dev-mode bash respawn loop, so `pkill` re-launches python
  instead of killing the container. Accepts `--dc <DC>`, `--env KEY=VALUE`
  (repeatable), `--name <suffix>`. Default DC is US-CA-2. Exposed as
  `npm run launch-test-pod`. ~$3/hr H100 SXM while running.

- **`terminate-test-pod.ts`** — Terminates a test pod by ID. Refuses to
  terminate any pod whose name doesn't start with `kiki-vtest-` (safety
  guard against killing real user sessions). Exposed as
  `npm run terminate-test-pod -- <podId>`.

- **`list-test-pods.ts`** — Lists currently-running test pods (filters by
  `kiki-vtest-*` prefix). Prints SSH + terminate commands per pod. Exposed
  as `npm run list-test-pods`. Run at the start of a session to spot
  forgotten pods.

### Diagnostics (`probe-*`)

- **`probe-dc-pulls.ts`** — Spin up N parallel pods per DC, time each through
  pod-create → scheduled → runtime-live. Used to isolate slow/stalled
  container pulls from the rest of the stack. Diagnostic for `fetching_image`
  variance across DCs.

- **`probe-spot-survival.ts`** — Get N spot 5090s per DC and watch them
  survive (or get preempted) for 10 minutes. Measures real-time preemption
  rate per DC.

- **`probe-ondemand-survival.ts`** — Same as `probe-spot-survival.ts` but
  on-demand pods (which aren't preempted). Tests create-reliability and
  runtime-stability without the preemption variable.

### Status checks (`check-*`)

- **`check-volume-versions.ts`** — Report the deployed app version on each
  network volume by querying PostHog for the most recent
  `pod.provision.completed` event per DC. Compares against local git HEAD.
  Free, fast. Limitation: only sees DCs that have served a recent provision —
  silent on long-cold DCs.

### One-off investigation (`debug-*`)

- **`debug-video-load.ts`** — Spawns a video pod and SSHs in to capture a
  full `video_pipeline.load()` traceback. Used when `/health` truncates the
  load_error or when you want a live shell during the failure. Not part of
  any routine flow.

## Common environment

All scripts that talk to RunPod need:

- `RUNPOD_API_KEY` — RunPod GraphQL auth
- `RUNPOD_SSH_PRIVATE_KEY` — for SSHing into spawned pods (sync/populate);
  set via `RUNPOD_SSH_PRIVATE_KEY="$(cat ~/.ssh/id_ed25519)"`
- `RUNPOD_REGISTRY_AUTH_ID` (optional) — Docker Hub auth for the
  `runpod/pytorch` base pull; reduces cold-host pull times

Scripts that read PostHog (`check-*`) need:

- `POSTHOG_PERSONAL_API_KEY`
- `POSTHOG_PROJECT_ID`

All of these live in `.env.local` at the repo root (gitignored). Most
scripts source it implicitly; check the script's docstring for specifics.
