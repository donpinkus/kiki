# LTX-2.3 — `torch.compile` canary SSH playbook

*Procedure for running the `torch.compile(mode="reduce-overhead")` experiment on a video pod **without** affecting production. Companion to `2026-04-30-torch-compile-failure.md` (the postmortem) and the perf plan in `.claude/plans/crystalline-squishing-rivest.md`.*

---

## Why a canary, not a production toggle

The previous attempt enabled `LTX_TORCH_COMPILE=1` in the orchestrator's `BOOT_ENV`, applying to every newly-booted video pod. `torch.compile()` is a lazy wrapper — the actual graph tracing/lowering runs on the first call to the wrapped model, which in our code is inside warmup's `_run_inference()`. When that lowering raised, the exception propagated out of `load()`, the pod marked itself not-ready, and the orchestrator's reaper terminated and re-provisioned the pod into an infinite crashloop.

Some failure modes can't be caught in Python at all — CUDA illegal memory access (segfault from the driver), OOM-kill (SIGKILL), C++ exceptions in extension modules, and `torch._inductor` failures that abort the process before raising back to Python. **No defensive `try/except` inside the same process can guarantee containment.** Only architectural isolation — running compile in a pod that user traffic never touches — protects production.

## How to actually run the canary (revised 2026-04-30)

**Use the test pod workflow** (`documents/perf-investigations/test-pod-workflow.md`), NOT the original "SSH into a production pod and pkill" approach. That earlier approach is broken because:

1. `pkill -f video_server.py` triggers the dev-mode bash respawn, which restarts python with the **same env** (`LTX_TORCH_COMPILE=0` from production `BOOT_ENV`) — so the canary swap never takes effect.
2. The orchestrator's reaper notices the pod is unresponsive during the ~30s respawn window and terminates it for being unhealthy. The whole pod gets replaced.

Test pods (`kiki-vtest-*` prefix) are invisible to the reaper and accept env overrides at launch time. Run:

```bash
cd backend && npm run launch-test-pod -- --env LTX_TORCH_COMPILE=1
```

Wait ~60–120s for the script to print SSH info. Then SSH in and watch warmup live:

```bash
ssh root@<ip> -p <port> -i ~/.ssh/id_ed25519
tail -f /proc/$(pgrep -f video_server | head -1)/fd/1
```

That's the canary. Production pods stay on `LTX_TORCH_COMPILE=0` (orchestrator's `BOOT_ENV`); user traffic is never affected.

---

## Prerequisites

- `RUNPOD_API_KEY` and `NETWORK_VOLUMES_BY_DC_VIDEO` set in `.env.local` (already are if you've ever run a deploy).
- Local `~/.ssh/id_ed25519.pub` exists (used by the launch script as the pod's `PUBLIC_KEY`).
- Familiarity with the test pod workflow at `documents/perf-investigations/test-pod-workflow.md`.

---

## Procedure

### Step 1: Launch a test pod with compile enabled

```
cd backend && npm run launch-test-pod -- --env LTX_TORCH_COMPILE=1
```

Wait ~60–120s for the script to print SSH info. The pod is named `kiki-vtest-<hex>` so the orchestrator's reaper ignores it.

### Step 2: SSH in and watch warmup live

The script prints the exact SSH command. In a separate terminal, tail the python stdout:

```
ssh root@<ip> -p <port> -i ~/.ssh/id_ed25519
tail -f /proc/$(pgrep -f video_server | head -1)/fd/1
```

`/proc/<pid>/fd/1` is the live stdout descriptor — works even though video_server's output isn't redirected to a file. If the python process dies, you can re-run the `tail` after `pgrep` shows a new pid (the bash respawn loop will restart it).

For longer-lived capture (in case of native crash), kill the respawn loop and run python directly with `nohup ... > /tmp/canary.log 2>&1`. See test-pod-workflow.md for that pattern.

### Step 3: Watch the warmup sequence

Expected sequence (each line ~1–10s apart):

1. `Loading LTX-2.3 ...` (pipeline init)
2. `LTX-2.3 pipeline loaded in 0.3s`
3. `LTX-2.3 building persistent transformer (Step 2)...`
4. `LTX-2.3 persistent transformer ready (~10s, vram_after=18.12 GiB)` — ✅ Step 2 worked
5. `LTX-2.3 torch.compile transformer (mode=reduce-overhead, lowering deferred to first call)...`
6. `LTX-2.3 torch.compile wrap call returned in ~1s` — ✅ wrap succeeded (we know this works)
7. `LTX-2.3 building persistent Gemma + embeddings_processor...`
8. `LTX-2.3 persistent Gemma ready`
9. `LTX-2.3 persistent embeddings_processor ready`
10. `LTX-2.3 warmup...`
11. **THE CRITICAL POINT**: first transformer call inside warmup triggers lazy compile.

What can happen at step 11:

#### Outcome A — Compile lowering succeeds

- Long pause (30s–5min) as dynamo traces, inductor lowers, CUDA graphs capture.
- Then: `LTX-2.3 warmup done (XXXs)` where XXX >> the eager baseline of ~9s.
- ✅ Compile is viable on this model. Proceed to Step 4.

#### Outcome B — Python exception

- Stack trace appears in the live tail.
- Python process exits; bash respawn loop restarts it (will hit the same error).
- ✅ We have the dynamo error message. Copy the traceback; skip to Step 5 (cleanup).

#### Outcome C — Native crash / OOM-kill

- Live tail stops; pgrep shows no python; bash respawns it; same crash; loop.
- Run `dmesg | tail -50` — look for OOM-kill, CUDA driver errors, segfaults.
- Run `nvidia-smi -q | head -50` — look for ECC errors or stuck GPU state.
- ❌ Compile fails in a way Python can't catch. Pivot to copy/cast attribution + native FP8 per the reviewer's revised priority list.

### Step 4 (success path only): Measure

- Note `warmup_inference_ms` from the log — this absorbs first-call compile latency (will be much higher than the ~9s eager baseline; the relevant number is what subsequent inferences take).
- Trigger an inference. The test pod isn't routed by the orchestrator, so:
  - Hit the WebSocket directly via a small `wscat` / python script from inside the pod (or from your Mac via the SSH-tunnel pattern).
  - The first inference at the warmup shape (320×320×49) hits the compiled cache and gives the real `pipe_total`.
- Compare measured `pipe_total` to the **3.74s eager baseline at 320×320×49** (from Step 3.5).
- If win > 10%, document; plan production rollout via canary-only env distinction + defensive scaffolding + `/health` observability fields.

### Step 5: Capture artifacts

From your local Mac (new terminal, not the SSH session):

If you've been tailing `/proc/<pid>/fd/1`, save the relevant section by hand. If you ran python with `nohup ... > /tmp/canary.log` instead, scp the file:

```
scp -P <port> -i ~/.ssh/id_ed25519 root@<ip>:/tmp/canary.log ~/Downloads/canary-$(date +%Y%m%d-%H%M%S).log
```

If Outcome C, also capture kernel-side info:
```
ssh root@<ip> -p <port> -i ~/.ssh/id_ed25519 'dmesg | tail -200' > ~/Downloads/canary-dmesg-$(date +%Y%m%d-%H%M%S).log
```

If Outcome A, also fetch the first decoded frame for output regression check:
```
scp -P <port> -i ~/.ssh/id_ed25519 root@<ip>:/tmp/ltx-first-frame.jpg ~/Downloads/canary-first-frame.jpg
```

### Step 6: Cleanup

```
cd backend && npm run terminate-test-pod -- <podId>
```

(The pod ID is what `launch-test-pod` printed at Step 1, or `npm run list-test-pods` to find it again.)

Production pods were never affected by this canary — they kept running with `LTX_TORCH_COMPILE=0` from the orchestrator's `BOOT_ENV` the whole time.

---

## Decision tree (after the canary run)

| Outcome | Verdict | Next step |
|---|---|---|
| **A** (compile works, win > 10%) | Compile is viable | Plan Phase 3 — `LTX_TORCH_COMPILE_EXPERIMENT=1` separate canary env, `_eager_transformer` save + warmup try/except + `torch._dynamo.reset()` on fallback, `/health` observability fields. Roll out only via canary pod path; production stays on eager. |
| **A** (compile works, win < 10%) | Compile not worth the complexity for this model | Skip Phase 3. Move to reviewer's Step P3 (copy/cast attribution + native FP8). |
| **B** (Python error) | Compile theoretically possible but needs work | Share full traceback with reviewer. Likely follow-ups: try `mode="default"` (no CUDA-graph requirement), patch the offending op in upstream `ltx-pipelines` (or wrap it in `@torch._dynamo.disable`), or skip the path entirely. |
| **C** (native crash) | Compile is dead on this model+stack | Move to reviewer's Step P3 (copy/cast attribution + native FP8). |

---

## Rollback if anything goes wrong mid-canary

If anything weird happens with the test pod, just terminate it: `npm run terminate-test-pod -- <podId>`, or via the RunPod web console. **Production user traffic was never affected** — test pods are a separate name prefix and the orchestrator doesn't touch them either way.

If for some reason you need to disable compile across all video pods quickly (you won't — the orchestrator already has `LTX_TORCH_COMPILE=0` in `BOOT_ENV`), confirm via `grep LTX_TORCH_COMPILE backend/src/modules/orchestrator/orchestrator.ts`. Should already be `'0'`.

---

## What this playbook intentionally doesn't do

- **No code changes to ship to all pods.** The compile experiment runs ONLY in the pod being canary'd, via the SSH-injected env var on the locally-launched python process. The volume's code, the orchestrator's `BOOT_ENV`, and Railway env are all untouched.
- **No defensive in-process fallback (`_eager_transformer` + warmup try/except + `dynamo.reset`).** Reviewer recommended this only for after canary proves compile works. Premature otherwise.
- **No new env flag plumbing** (`LTX_TORCH_COMPILE_EXPERIMENT`). Same reason — that's Phase 3.

If the canary succeeds and we want to scale up, all of those become required changes. They're tracked in the perf plan's Phase 3.
