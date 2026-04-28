# `backend/scripts/`

Operational scripts for the RunPod side of the stack. All run from `backend/`
via `npx tsx scripts/<name>.ts`.

## Naming convention

Three families, distinguished by the verb:

| Prefix       | Purpose                              | Mutates state? | Costs $? |
| ------------ | ------------------------------------ | -------------- | -------- |
| `populate-*` | First-time provisioning of a volume  | yes            | yes      |
| `sync-*`     | Push code/dep updates to a volume    | yes            | yes      |
| `probe-*`    | Measure RunPod *behavior* over time  | no             | yes      |
| `check-*`    | Read-only point-in-time status       | no             | usually no |

When adding a new script, pick the prefix that matches the verb you'd use to
describe it. `probe-*` and `check-*` differ in that probes spin up real pods
to observe RunPod's behavior under conditions; checks read existing telemetry
or APIs.

## Scripts

### Volume management (`populate-*`, `sync-*`)

- **`populate-volume.ts`** — First-time setup of a network volume. Spawns a
  5090, downloads ~25 GB of FLUX.2-klein weights into `/workspace/huggingface/`,
  then terminates. Run once per DC volume at provisioning time. ~15 min, ~$0.20.

- **`sync-flux-app.ts`** — Push updates to `flux-klein-server/*.py` and
  `requirements.txt`. Spawns a cheap pod, rsyncs files into `/workspace/app/`,
  pip-installs into `/workspace/venv/`, writes `/workspace/app/.version.json`
  with the local git SHA, terminates. Run per DC after every code change to
  the FLUX server. ~5–10 min, ~$0.10.

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
