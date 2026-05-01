# Pod operations — decision tree + runbook

*Single source of truth for "how do I update / iterate on / debug / terminate a pod." Every task below is self-contained: copy the commands, run them, get the expected output. You should not need to open another doc to complete a listed task. Cross-references at the bottom of each section are for deeper architecture context only.*

**Last verified working:** 2026-05-01. If you re-validate end-to-end, please bump this date.

---

## Quick orientation

Two pod kinds, different GPUs, same network volumes + same orchestrator:

- **Image pod** — RTX 5090, runs `flux-klein-server/server.py` (FLUX.2-klein, the live img2img path). Name prefix `kiki-session-*`.
- **Video pod** — H100 SXM 80 GB, runs `flux-klein-server/video_server.py` (LTX-2.3 22B distilled FP8, the idle-state animation). Name prefix `kiki-vsession-*`.

Pods boot from stock `runpod/pytorch:1.0.3-cu1281-torch291-ubuntu2404` (hardcoded as `BASE_IMAGE` in `backend/src/modules/orchestrator/orchestrator.ts`) and read app code + venv off attached network volumes (one volume per DC, populated via `backend/scripts/sync-flux-app.ts`).

The orchestrator (Railway-hosted backend) provisions, monitors, and reaps pods. Reaping is **prefix-filtered**: it only touches pods named `kiki-session-*` or `kiki-vsession-*`. Manually-launched **test pods** use the prefix `kiki-vtest-*` and are invisible to the reaper — that's the escape hatch for risky experiments.

---

## Global prerequisites (state once, applies to all tasks)

These need to be in place before running any task. If you can run `cd backend && npm run list-test-pods` and it doesn't error, you have everything.

- **Working dir** for `npm run` commands: `backend/`. The deploy script also requires being in `backend/` because Railway CLI uses cwd to find the project.
- **`.env.local` at repo root** — must contain at minimum:
  - `RUNPOD_API_KEY` — the RunPod GraphQL API key, used for all pod create/list/terminate operations
  - `NETWORK_VOLUMES_BY_DC` (image-pod volumes) — JSON map `{"DC-NAME": "volumeId", ...}`
  - `NETWORK_VOLUMES_BY_DC_VIDEO` (video-pod volumes) — same shape
  - Optional: `RUNPOD_REGISTRY_AUTH_ID`, `POSTHOG_PERSONAL_API_KEY`
- **Local SSH key** at `~/.ssh/id_ed25519`. The `.pub` half is what test pods use as `PUBLIC_KEY` to allow your SSH in.
- **Railway CLI** installed and logged in (`railway status` should print the project info). The repo's `~/.railway/config.json` already has the project linked.
- **gh CLI** for the rare "kill everything" workflow (Task 7c).

---

## Task index

| # | Task | Command (summary) |
|---:|---|---|
| 1 | Ship a pod-side code change to all users (permanent) | `cd backend && npm run deploy` |
| 2 | Ship a backend-only change (no pod code modified) | `cd backend && railway up` |
| 3 | Iterate on pod-side code without re-deploying (fast loop) | `npm run launch-test-pod` + scp + pkill |
| 4 | Run a risky experiment that might break the pod | `npm run launch-test-pod -- --env KEY=VALUE` |
| 5 | Verify a pod is healthy | `curl https://<pod-id>-8766.proxy.runpod.net/health` |
| 6 | See what test pods are running | `npm run list-test-pods` |
| 7 | Terminate a pod | `npm run terminate-test-pod -- <id>` (test) / web console (prod) / `gh workflow run stop-pods.yml` (nuclear) |
| 8 | SSH into a production pod for read-only debugging | RunPod web console → "SSH over exposed TCP" |
| 9 | Bump the base image (CUDA / PyTorch upgrade) | Multi-step coordinated procedure — read carefully |
| 10 | Roll back to the old GHCR custom-image flow (emergency) | Multi-step rollback — also read carefully |

---

## Task 1: Ship a pod-side code change to all users (permanent)

When you've edited a file in `flux-klein-server/` and want every newly-booted pod (and eventually all running ones, after they get reaped + re-provisioned) to use the new code.

### Command

```bash
cd backend && npm run deploy
```

### What you'll see

The script (`backend/scripts/deploy.ts`) prints `[deploy]` log lines as it works. Roughly:

```
[deploy] flux-klein-server changed since last deploy: <oldHash> → <newHash>
[deploy] running sync-all-dcs first...
[sync-all] launching N parallel syncs: EU-CZ-1, EU-NL-1, ...
[sync-all] per-DC logs: /tmp/sync-all-<DC>.log
[sync-all] each sync takes ~70s when nothing changed, 5-10 min on first sync
[sync-all] summary:
  ✓ EU-CZ-1    (117s, exit=0, log=/tmp/sync-all-EU-CZ-1.log)
  ✓ EU-NL-1    (107s, exit=0, log=/tmp/sync-all-EU-NL-1.log)
  ...
[deploy] stamped .flux-app-version=<newHash> .git-sha=<commit>
[deploy] running railway up...
Indexing...
Uploading...
  Build Logs: https://railway.com/project/.../...
```

Then a Railway build runs (~50s). Watch the build logs URL or `railway status --json` for "SUCCESS".

### Time

~5–15 min total. Sync-all dominates and varies with stockout luck.

### Failure modes

- **One or more DCs failed in sync-all** (exit code 1, "X/Y DCs failed"). The script aborts before `railway up` and does NOT update `.flux-app-version` (so the next `npm run deploy` will retry). Most common cause: RunPod GPU stockout in those DCs (we observed this regularly for US-IL-1, US-NC-1, US-TX-3 during this session). Recovery options:
  - Wait 15-30 min and re-run `npm run deploy` (capacity often returns).
  - If the failed DCs aren't critical and you need to ship now, manually update `.git-sha` to the current `git rev-parse HEAD` and run `cd backend && railway up` to deploy backend without a fresh sync. The orchestrator's drift check will fire a Sentry warning when those stale DCs serve a pod, but it's not silent.
- **`railway up` build failed.** Check the printed build logs URL. Usually a TypeScript error or a missing package — fix and re-run.
- **Build SUCCESS but pods don't pick up new code.** Existing running pods keep the old in-memory copy. Either wait for the orchestrator's idle reaper (30 min) or terminate them manually via the RunPod web console.

### What's happening

`scripts/deploy.ts` reads `backend/.flux-app-version` (the flux-klein-server tree-hash from the last successful deploy). If it differs from `git rev-parse HEAD:flux-klein-server`, the script fans out `sync-flux-app.ts` to each DC in `NETWORK_VOLUMES_BY_DC` + `NETWORK_VOLUMES_BY_DC_VIDEO`. Each sync briefly creates a tiny GPU pod with the volume attached, rsyncs `flux-klein-server/*.py` to `/workspace/app/`, ensures `/workspace/venv/` is current with `requirements.txt`, then terminates that sync pod. After all syncs succeed, the script stamps the new hash into `.flux-app-version` + `.git-sha` and runs `railway up`. The orchestrator's drift check at pod boot reads `.flux-app-version` to detect cases where someone bypassed the script.

For more on the pod boot model, see CLAUDE.md "Deploy Process".

---

## Task 2: Ship a backend-only change (no pod code modified)

When you've only touched files in `backend/src/` (orchestrator, routes, env vars, cost monitor, etc.) and `flux-klein-server/` is unchanged.

### Command

```bash
cd backend && railway up
```

### What you'll see

```
Indexing...
Uploading...
  Build Logs: https://railway.com/project/.../...
```

The build takes ~50s. Then Railway transitions through BUILDING → DEPLOYING → SUCCESS. Check via:

```bash
railway status --json | python3 -c "import sys, json; d=json.loads(sys.stdin.read()); print(d['environments']['edges'][0]['node']['serviceInstances']['edges'][0]['node']['latestDeployment']['status'])"
```

### Time

~1–2 min total.

### Failure modes

- **Build fails.** Check the printed URL. Usually a TypeScript error (`tsc` would have caught it locally if you ran `npm run build` first).
- **Deployment status stays FAILED with no visible error.** Rare — try once more (`railway up` again). If it persists, check Railway dashboard for runtime logs of the failed deployment.

### What's happening

Bypasses the auto-sync gate in `npm run deploy`. Uploads the current `backend/` tree directly to Railway via their CLI; Railway builds from `backend/Dockerfile`. Skips DC volume work entirely — appropriate when no pod-side file changed. **Don't use this when you've edited `flux-klein-server/` files**: the orchestrator will report drift in Sentry but pods will keep running the old code.

---

## Task 3: Iterate on pod-side code without re-deploying (fast loop)

When you're actively debugging or experimenting on `flux-klein-server/*.py` and `npm run deploy`'s ~10 min cycle is too slow. Use a test pod for a ~30s iteration loop.

### Setup (once per session)

```bash
cd backend && npm run launch-test-pod
```

You'll see:

```
[launch-test-pod] DC=US-CA-2 volume=4iq4uchi49 name=kiki-vtest-<hex>
[launch-test-pod] env: ...
[launch-test-pod] creating on-demand pod (H100 SXM 80GB)...
[launch-test-pod] pod created: id=<podId> costPerHr=$2.99/hr
[launch-test-pod] waiting for SSH ports to be assigned...
[launch-test-pod] status: RUNNING runtime=yes

✅ Test pod ready: kiki-vtest-<hex> (<podId>)

SSH:
  ssh root@<ip> -p <port> -i ~/.ssh/id_ed25519
...
```

Note the IP, port, and pod ID — you'll use them in the iteration loop and at cleanup.

Pod boot takes ~60–120s (SSH ports assigned) + ~30s (uvicorn starts) + ~10s (warmup) before it's serving. During that window, `curl https://<podId>-8766.proxy.runpod.net/health` returns 502.

### Per-iteration commands (paste-ready)

Substitute your own `<port>` and `<ip>` from launch output:

```bash
# 1. From repo root, scp the modified file to the pod
scp -P <port> -i ~/.ssh/id_ed25519 \
    flux-klein-server/video_pipeline.py \
    root@<ip>:/workspace/app/

# 2. Restart python — bash respawn loop catches the exit
ssh -p <port> -i ~/.ssh/id_ed25519 root@<ip> 'pkill -f video_server.py'

# 3. Tail the new python's live stdout (works through respawn)
ssh -p <port> -i ~/.ssh/id_ed25519 root@<ip> \
    'tail -f /proc/$(pgrep -f video_server | head -1)/fd/1'
```

Step 2's SSH connection may drop with `Connection closed by remote host` — that's normal during pkill. Just reconnect; bash already respawned python.

Step 3's tail will show:
- `Loading LTX-2.3 ...` (or the equivalent for image-pod's `server.py`)
- `LTX-2.3 pipeline loaded in ...`
- Persistent transformer / Gemma builds (~10s + ~6s)
- `LTX-2.3 warmup...` then `warmup done (~9s)`
- (Then idle, awaiting WebSocket connections)

### Time

- First launch: ~60–120s
- Each scp+respawn: ~30s

### Failure modes

- **launch-test-pod times out at "waiting for SSH port assignment"** (>5 min). Pod hit a stocked-out DC. Re-run with `--dc <other>` (valid DCs printed when you pass `--help`).
- **`scp: Host key verification failed`.** Stale `known_hosts` entry from a prior pod that reused the same IP+port. Fix: `ssh-keygen -R "[<ip>]:<port>"`, then re-scp.
- **`pkill` kills the WHOLE pod, not just python.** Should not happen on a test pod. If it does (you see the pod disappear from `npm run list-test-pods`), it means `PUBLIC_KEY` wasn't set when the pod was launched — production mode `exec python3` makes python PID 1 and killing PID 1 kills the container. The launch script always sets `PUBLIC_KEY` to force dev-mode bash respawn loop, so this should not occur unless you tampered.

### CRITICAL: don't do this on a production pod

If you SSH into a `kiki-vsession-*` (production video) or `kiki-session-*` (production image) pod and run `pkill -f video_server.py`:

1. The bash respawn loop restarts python with the SAME env (so any LOCAL env override you set won't apply).
2. During the ~30s python restart, `/health` returns 502.
3. The orchestrator's reaper detects the pod is unhealthy after 60s and terminates it.
4. The user's session breaks; orchestrator provisions a new pod.

This is exactly the failure mode we hit on 2026-04-30. The test pod workflow exists to avoid it.

### What's happening

Test pods are provisioned with the name prefix `kiki-vtest-*` which the orchestrator's `listPodsByPrefix` filter doesn't match — they're invisible to the reaper. The launch script always passes `PUBLIC_KEY` (your `~/.ssh/id_ed25519.pub`), which triggers the dev-mode branch of `BOOT_DOCKER_ARGS`: `while true; do python3 -u video_server.py; sleep 2; done` instead of `exec python3 -u video_server.py`. Bash stays as PID 1 and respawns python on each exit. So `pkill` ends a python process; bash starts a new one with the new code.

For deeper troubleshooting (custom env vars, multi-pod usage, cost), see `documents/perf-investigations/test-pod-workflow.md`.

---

## Task 4: Run a risky experiment that might break the pod

Same as Task 3, but with a custom env var that the production code reads. Useful for trying `LTX_TORCH_COMPILE=1`, `LTX_FP8_MODE=scaled_mm`, `LTX_PERSIST_GEMMA=0`, etc.

### Command

```bash
cd backend && npm run launch-test-pod -- --env LTX_TORCH_COMPILE=1
# or stack multiple env vars:
cd backend && npm run launch-test-pod -- --env LTX_TORCH_COMPILE=1 --env FOO=bar
```

### What you'll see

Same as Task 3, but the printed env line shows your override:

```
[launch-test-pod] env: HF_HOME=... PYTORCH_CUDA_ALLOC_CONF=... LTX_TORCH_COMPILE=1 PUBLIC_KEY=<redacted>
```

### Workflow

1. Launch as above.
2. Wait for `/health` to either become ready (success) or return `load_error` (Python exception). Poll with `curl https://<podId>-8766.proxy.runpod.net/health` every 15s, or just SSH in and tail stdout.
3. If the experiment crashes natively (process gone, no Python error), check `dmesg | tail -50` over SSH for OOM-kill or CUDA driver errors. Native crashes can't be caught in Python; this is exactly why the experiment has to run in isolation.
4. When done, terminate (Task 7).

### Time

Pod launch: ~60–120s. Experiment timeline depends on what you're testing — a `torch.compile` warmup, for example, can take 5–15 min for first lowering on a 22B-param transformer.

### CRITICAL: don't enable risky experiments via the orchestrator's BOOT_ENV

Adding `{ key: 'LTX_TORCH_COMPILE', value: '1' }` to the `BOOT_ENV` array in `backend/src/modules/orchestrator/orchestrator.ts` applies to every newly-booted production pod. We learned this on 2026-04-30 when shipping `LTX_TORCH_COMPILE=1` crashlooped every video pod. Pre-test risky env changes via Task 4 first.

### What's happening

Same as Task 3, plus the env override is passed to the pod via RunPod's GraphQL `env: [...]` array at create time. The pod-side code reads `os.getenv('LTX_TORCH_COMPILE', '0')` etc.

For a worked example, see `documents/perf-investigations/2026-04-30-torch-compile-canary-playbook.md` and `documents/perf-investigations/2026-05-01-compile-experiments-and-p3-findings.md`.

---

## Task 5: Verify a pod is healthy

When you want to confirm a pod is up, see what state it's in, or capture a Python load error.

### Command

```bash
curl https://<pod-id>-8766.proxy.runpod.net/health
```

Get `<pod-id>` from `npm run list-test-pods` (test pods), the RunPod web console (production), or Railway logs (the orchestrator logs every pod it provisions).

### What you'll see

**Healthy:**

```json
{
  "status": "ok",
  "video_ready": true,
  "model_family": "LTX-2.3",
  "gpu": "NVIDIA H100 80GB HBM3",
  "load_ms": 27000,
  "phase_timings_ms": { "warmup_inference_ms": 9000, ... },
  "persistent_transformer_ready": true,
  "persistent_gemma_ready": true,
  "vram_after_embeddings_processor_gb": 46.73,
  ...
}
```

**Still loading:**

```json
{ "status": "loading", "video_ready": false, ... }
```

**Pipeline failed during startup (this is the canonical way to read a load error):**

```json
{
  "status": "error",
  "load_error": "Traceback (most recent call last):\n  File \"/workspace/app/video_server.py\", line 81, in lifespan\n    video_pipeline.load()\n  ..."
}
```

### Time

Instant once the pod's HTTP service is up. During pod boot, this returns 502 instead.

### Failure modes

- **HTTP 502 from RunPod proxy.** Pod's uvicorn isn't bound yet. Wait 30–120s and retry. If still 502 after ~5 min, check `npm run list-test-pods` (or RunPod web console for production) — the pod may have died entirely.
- **Connection refused / DNS error.** The pod is gone (terminated, never came up, or wrong pod ID).
- **Returns valid JSON but `load_error` is set.** Pipeline crashed during startup with a Python exception. The traceback in `load_error` is the full Python stack — paste into a file and read top-to-bottom.

### What's happening

RunPod's HTTPS proxy at `https://<pod-id>-<port>.proxy.runpod.net` forwards to the pod's container port. The video_server's `/health` endpoint (`flux-klein-server/video_server.py`) returns the cached `_load_error_traceback` if pipeline load failed, otherwise the in-memory pipeline state from `Ltx23VideoPipeline.get_info()`.

`provider-config.md` has a related GraphQL snippet for listing pod IDs directly via the RunPod API — useful when you don't have the web console handy.

---

## Task 6: See what test pods are running

Run this at the start of any session to spot forgotten test pods. Cost is negligible per CLAUDE.md "Cost during dev/testing", but cleanliness still matters.

### Command

```bash
cd backend && npm run list-test-pods
```

### What you'll see

If pods are alive:

```
2 test pod(s):

  abc123  name=kiki-vtest-456aff  dc=US-CA-2  status=RUNNING  uptime=0.5h
    ssh root@<ip> -p <port> -i ~/.ssh/id_ed25519
    npm run terminate-test-pod -- abc123

  xyz789  name=kiki-vtest-789def  dc=EU-NL-1  status=RUNNING  uptime=2.3h
    ...
```

If clean: `No test pods running.`

### Time

~3s.

### Production pods aren't shown here

This script filters by the `kiki-vtest-*` prefix only. Production session pods (`kiki-session-*`, `kiki-vsession-*`) are managed by the orchestrator and listed in the RunPod web console. Don't terminate them manually — let the idle reaper handle them, or close the iPad WS to trigger orchestrator cleanup.

### What's happening

Calls RunPod's GraphQL `myself { pods { ... } }` endpoint, filters to the `kiki-vtest-*` prefix, then per-pod fetches runtime info to print SSH command + uptime.

---

## Task 7: Terminate a pod

### 7a. Terminate a test pod

```bash
cd backend && npm run terminate-test-pod -- <podId>
```

The script refuses to terminate anything not prefixed `kiki-vtest-` — protects against accidentally killing user sessions. Time: ~3s.

### 7b. Terminate a production session pod

Don't, normally. Either:

- **Close the iPad WS.** That triggers the orchestrator's session cleanup (~30 min idle reap if no reconnect, faster if the next session uses a different DC).
- **Wait for the idle reaper.** Active sessions are reaped after 30 min of no traffic.
- **Force-kill via RunPod web console.** If you really need to kill a specific production pod (e.g., it's wedged), find it in the console and click "Terminate". The orchestrator detects the missing pod and the next iPad session provisions a fresh one.

### 7c. Nuclear: terminate every pod on the RunPod account

```bash
gh workflow run stop-pods.yml
```

Runs the GitHub Actions workflow at `.github/workflows/stop-pods.yml`. Lists every pod owned by the RUNPOD_API_KEY and terminates them in parallel. Use only when:

- Costs spike unexpectedly (cost panic button).
- You want a guaranteed clean state before a test.
- You suspect a stuck pod is causing iPad session weirdness.

After triggering, the orchestrator will provision new pods on the next iPad session — no further action needed for recovery.

Time: workflow run is ~30s but check `gh run list --workflow=stop-pods.yml` for status.

### What's happening

`terminate-test-pod` calls RunPod's GraphQL `podTerminate(input: { podId })` with a name-prefix safety check. The Actions workflow does the same call but for every pod returned by `myself { pods }`.

---

## Task 8: SSH into a production pod for read-only debugging

When a user's pod is misbehaving and you want to inspect logs, GPU state, or files. Read-only operations only. **Do not pkill or modify state** — that triggers the orchestrator's reaper.

### Prerequisite: enable SSH for the session

`PUBLIC_KEY` must be set on Railway before pods are provisioned. If it's not:

```bash
PUB="$(cat ~/.ssh/id_ed25519.pub)"
railway variables --service kiki-backend --set "PUBLIC_KEY=$PUB"
cd backend && npm run deploy
# Existing pods keep the no-SSH path; terminate them so the orchestrator
# provisions new ones with sshd active.
```

### Connect

RunPod web console → click the pod → **Connect** tab → use the **"SSH over exposed TCP"** form (NOT the proxy `ssh.runpod.io` form — that one rejects SCP/SFTP and non-interactive commands). Copy and paste the displayed command:

```
ssh root@<ip> -p <port> -i ~/.ssh/id_ed25519
```

### What you can safely do

- **Tail live python stdout:**
  ```
  tail -f /proc/$(pgrep -f video_server | head -1)/fd/1
  ```
- **Inspect GPU state:** `nvidia-smi`, `nvidia-smi -q | head -50`
- **Check files:** `ls /workspace/app/`, `cat /tmp/ssh-bootstrap.log`, `df -h /workspace`
- **Read pod env:** `cat /proc/1/environ | tr '\0' '\n'` (root is allowed)
- **Check kernel state:** `dmesg | tail -50` (look for OOM-kill, CUDA errors)

### What you must NOT do

- **Do not `pkill -f video_server.py`.** The orchestrator's reaper will detect /health unresponsive within 60s and terminate the pod, breaking the user's session. To iterate on code changes, use Task 3 (test pod workflow).
- **Do not `rm` or modify files in `/workspace/app/`.** That state is per-pod-instance and gets clobbered by the next pod boot, but it might be sticky enough during the session to cause a regression.
- **Do not install packages with `pip install`.** Same reason.

### Disable SSH for prod

```bash
railway variables --service kiki-backend --remove "PUBLIC_KEY"
# Or set it to empty string. Newly-spawned pods skip the bootstrap.
# Existing pods retain whichever path was active when they booted.
```

### What's happening

`PUBLIC_KEY` in Railway env is forwarded into the pod's `BOOT_ENV` at pod-create time. The inline bootstrap in `BOOT_DOCKER_ARGS` (orchestrator.ts) writes `~/.ssh/authorized_keys`, runs `ssh-keygen -A`, then `service ssh start` (with `/usr/sbin/sshd` fallback) — all logged to `/tmp/ssh-bootstrap.log` for forensics. After that, sshd is listening on port 22, exposed via the RunPod TCP port mapping.

If SSH refuses connection, check `/tmp/ssh-bootstrap.log` from the RunPod web console "Logs" tab to see if `ssh-keygen -A` failed or `service ssh start` couldn't bind.

For more, see CLAUDE.md "SSHing into a running pod".

---

## Task 9: Bump the base image (CUDA / PyTorch upgrade)

NOT a one-line change. The base image's Python/CUDA ABI must match the venv at `/workspace/venv/` (which has `.so` files compiled against a specific Python+CUDA combo). Bumping the image without rebuilding the venv produces undefined behavior at best, segfaults at worst.

### Procedure (do not run without coordination)

1. **Update the constant** in `backend/src/modules/orchestrator/orchestrator.ts`:
   ```typescript
   const BASE_IMAGE = 'runpod/pytorch:<new-tag>';
   ```

2. **For each DC volume** (5 video DCs + 5 image DCs, listed in `.env.local` `NETWORK_VOLUMES_BY_DC` and `NETWORK_VOLUMES_BY_DC_VIDEO`):
   - Manually launch a one-off pod with the NEW base image attached to that DC's volume.
   - SSH in, `rm -rf /workspace/venv`.
   - From your local machine: `cd backend && npx tsx scripts/sync-flux-app.ts --dc <DC> --volume-id <id>`. This rebuilds the venv from `flux-klein-server/requirements.txt` against the new base.
   - Terminate the manual pod.

3. **Verify a test pod boots cleanly with the new image.** Update `backend/scripts/launch-test-pod.ts` `BASE_IMAGE` constant if you've also bumped it locally for testing. Run a `npm run launch-test-pod` smoke test, watch warmup complete, run one inference (Task 4 + your own WS trigger).

4. **`cd backend && npm run deploy`.** Backend deploys, sync-all-dcs sees no flux-klein-server change (skips), `railway up` ships the orchestrator with the new BASE_IMAGE. Newly-provisioned pods now use the new base.

5. **Old running pods** keep running with the old base until reaped.

### Time

~30–60 min total because the per-DC venv rebuild is sequential by necessity (~3 min each × 10 DCs).

### Why it's not env-driven

The base image tag is hardcoded as `BASE_IMAGE` in orchestrator.ts (not a Railway env var) precisely because bumping it requires this coordinated venv rebuild — making it a config flip would invite someone to change it without doing the rebuild and break every new pod silently. See `documents/decisions.md` 2026-04-23 entry.

---

## Task 10: Roll back to the old GHCR custom-image flow (emergency only)

The pre-2026-04-23 architecture (custom image at `ghcr.io/donpinkus/kiki-flux-klein:<sha>`, built by `.github/workflows/build-flux-image.yml`) is retained as inactive code for emergency rollback. Don't use this in normal operations — it's slower, less reliable, and was specifically replaced for those reasons.

### Rollback procedure

1. **`git revert <cutover-commit>`** — brings back the orchestrator + iOS changes + config fields. The cutover commit is the one referenced in `documents/decisions.md` 2026-04-23 entry.
2. **On Railway:** set `FLUX_IMAGE` and `RUNPOD_GHCR_AUTH_ID` again. Last known-good tag: `ghcr.io/donpinkus/kiki-flux-klein:<sha>` for whichever commit precedes the cutover on main. GHCR retains old tags indefinitely; no rebuild needed.
3. **`cd backend && railway up`.**
4. **Rebuild iOS in Xcode, reconnect.**
5. `/workspace/venv/` and `/workspace/app/` directories on the volumes are harmless to leave; the rolled-back orchestrator ignores them.

### After rollback

Follow `documents/decisions.md` 2026-04-23 entry's "After stage-3 cleanup" notes if you need additional steps (restoring Dockerfile + GHA workflow from history, or rebuilding the GHCR image if its tag was pruned).

### Why this is emergency-only

The GHCR flow had ~38% of provisions stalling on hosts that couldn't reliably pull from `ghcr.io`. Each stall added 120–240s of user-visible wait. The current volume-entrypoint flow eliminated those stalls and reduced cold start from ~110–150s to ~96s avg. Rolling back reintroduces those problems.

---

## Cross-references (for deeper context)

The above tasks are operationally complete. These docs explain the WHY and the architecture in more detail:

- **`CLAUDE.md` § "Deploy Process"** — the pod-boot model, `.flux-app-version` semantics, GHCR rollback trigger conditions.
- **`CLAUDE.md` § "SSHing into a running pod"** — pre-launch SSH bootstrap details, the inline BOOT_DOCKER_ARGS bash script that sets up sshd.
- **`documents/perf-investigations/test-pod-workflow.md`** — extended troubleshooting for the test pod iteration loop.
- **`documents/references/provider-config.md`** — orchestration architecture (state machine, network volumes, key files), cost numbers, observability log lines, RunPod GraphQL pod-listing snippet.
- **`documents/references/runpod-model-serving-playbook.md`** — getting a model PERFORMANT on a pod (persistent-model architecture, OOM/perf diagnosis). Different concern from "operations".
- **`documents/decisions.md` 2026-04-23 entry** — full context on the volume-entrypoint cutover (Task 9 + Task 10 background).
- **`documents/perf-investigations/2026-04-30-torch-compile-failure.md`** + **`2026-04-30-torch-compile-canary-playbook.md`** — worked example of why "test pod for risky experiments" exists (Task 4 background).
