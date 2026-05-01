# LTX-2.3 — `torch.compile` canary SSH playbook

*Procedure for running the `torch.compile(mode="reduce-overhead")` experiment on a video pod **without** affecting production. Companion to `2026-04-30-torch-compile-failure.md` (the postmortem) and the perf plan in `.claude/plans/crystalline-squishing-rivest.md`.*

---

## Why a canary, not a production toggle

The previous attempt enabled `LTX_TORCH_COMPILE=1` in the orchestrator's `BOOT_ENV`, applying to every newly-booted video pod. `torch.compile()` is a lazy wrapper — the actual graph tracing/lowering runs on the first call to the wrapped model, which in our code is inside warmup's `_run_inference()`. When that lowering raised, the exception propagated out of `load()`, the pod marked itself not-ready, and the orchestrator's reaper terminated and re-provisioned the pod into an infinite crashloop.

Some failure modes can't be caught in Python at all — CUDA illegal memory access (segfault from the driver), OOM-kill (SIGKILL), C++ exceptions in extension modules, and `torch._inductor` failures that abort the process before raising back to Python. **No defensive `try/except` inside the same process can guarantee containment.** Only architectural isolation — running compile in a pod that user traffic never touches — protects production.

This playbook is the isolation mechanism. It uses the existing SSH dev-iteration loop (documented in `CLAUDE.md` "SSHing into a running pod") to swap a healthy pod's running server for one that has compile enabled, watch the result, and clean up. Production `BOOT_ENV` keeps `LTX_TORCH_COMPILE=0` regardless of the canary outcome.

---

## Prerequisites

- A clean video pod is currently running with the production env (`LTX_TORCH_COMPILE=0` from `BOOT_ENV`, set by the orchestrator).
- `PUBLIC_KEY` is set on Railway (so newly-booted video pods come up with sshd running).
- The pod has gone through normal warmup (`/health` returns ready).
- Local `~/.ssh/id_ed25519` matches the public key on Railway.

If `PUBLIC_KEY` is unset on Railway, see the SSH bootstrap section in `CLAUDE.md` for how to enable it (one Railway env var + one redeploy).

---

## Procedure

### Step 1: Get the pod's SSH info

RunPod web console → Pods → click the running video pod → **Connect** tab → use the **"SSH over exposed TCP"** form. (Do NOT use the proxy `ssh.runpod.io` form — it rejects non-interactive SCP/SFTP.)

Copy the displayed command, e.g.:
```
ssh root@91.199.227.82 -p 11323 -i ~/.ssh/id_ed25519
```

Save the IP and port — both are reused below for `scp`.

### Step 2: SSH into the pod

```
ssh root@<ip> -p <port> -i ~/.ssh/id_ed25519
```

### Step 3: Stop the running production server

```
pkill -f video_server.py
sleep 2
ps aux | grep video_server | grep -v grep   # confirm no python video_server process remains
```

### Step 4: Restart with compile enabled, logging to disk

```
cd /workspace/app
source /workspace/venv/bin/activate
LTX_TORCH_COMPILE=1 nohup python3 -u video_server.py > /tmp/canary.log 2>&1 & disown
echo "started pid $(pgrep -f video_server.py)"
```

Notes:
- `python3 -u` forces unbuffered stdout. Without it, the buffer might not flush before a crash and we lose the error.
- `nohup ... & disown` keeps the process alive across SSH disconnect.
- Logging to `/tmp/canary.log` so the artifact survives even if SSH drops.

### Step 5: Watch live output

```
tail -f /tmp/canary.log
```

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
- Then: `LTX-2.3 warmup done (XXXs)` where XXX > the eager baseline of ~9s.
- Pod becomes ready (note: it's now ready against THIS canary process, not the orchestrator-managed one — the orchestrator may not route traffic here unless we manually trigger).
- ✅ Compile is viable on this model. Proceed to Step 6.

#### Outcome B — Python exception

- Stack trace appears in `/tmp/canary.log`.
- Process exits or hangs at the warmup line.
- ✅ We have the dynamo error message. Save the full traceback. Skip to Step 7 (cleanup) and Step 8 (analysis).

#### Outcome C — Native crash / OOM-kill

- Logs cut off mid-stream.
- `tail -f` shows the file stops growing.
- Run `ps aux | grep video_server | grep -v grep` — process gone.
- Run `dmesg | tail -50` — look for OOM-kill messages, CUDA driver errors, segfaults.
- Run `nvidia-smi -q | head -50` — look for ECC errors or stuck GPU state.
- ❌ Compile fails in a way Python can't catch. Pivot to Step P3 (copy/cast attribution + native FP8) per the reviewer's revised priority list.

### Step 6 (success path only): Measure

- Note `warmup_inference_ms` from the log — this absorbs first-call compile latency (will be much higher than the ~9s eager baseline).
- Trigger a video. Two options:
  - Easier but indirect: open the iPad and start a new session. The orchestrator may route to a different pod since it doesn't know about this canary process. If you got the same pod, the request will hit the compiled cache and produce a `pipe_total` measurement.
  - Direct: from inside the pod, hit the WebSocket with `wscat`:
    ```
    pip install --break-system-packages websockets  # if needed; in-pod is fine to dirty
    python3 -c 'import asyncio, websockets, base64, json; ...'   # assemble a video_request
    ```
    Bit of work. Stick with the iPad route unless really needed.
- Compare measured `pipe_total` to the **3.74s eager baseline at 320×320×49** (from Step 3.5).
- If win > 10%, document; propose Phase 3 (canary-only env distinction + defensive scaffolding + `/health` observability fields).

### Step 7: Cleanup (always, regardless of outcome)

Two options — pick one:

**(a) Recommended: Terminate the pod from the RunPod web console.** The orchestrator detects the missing pod and provisions a fresh one with production env (`LTX_TORCH_COMPILE=0`). Cleanest — no risk of lingering canary state.

**(b) Restart the production server in-pod:**
```
pkill -f video_server.py
sleep 2
cd /workspace/app && source /workspace/venv/bin/activate
nohup python3 -u video_server.py > /tmp/video_server.log 2>&1 & disown
```
The new process inherits the pod's `BOOT_ENV` (production, `LTX_TORCH_COMPILE=0`). Faster than (a) but assumes pod state is clean.

### Step 8: Capture artifacts

From your local Mac (new terminal, NOT the SSH session):

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

If you can't SSH back in, can't run `pkill`, or anything else weird happens — **just terminate the pod from the RunPod web console.** The orchestrator will provision a fresh one with production `BOOT_ENV` (compile off). Production user traffic was never affected because the canary swapped only the pod's local process, never the orchestrator-side env.

If for some reason you need to disable compile across all video pods quickly (you won't — the orchestrator already has it disabled), edit `backend/src/modules/orchestrator/orchestrator.ts` `BOOT_ENV` line:
```typescript
{ key: 'LTX_TORCH_COMPILE', value: '0' },  // already this; canary doesn't change it
```
Then `cd backend && railway up`. New pods boot with the production env.

---

## What this playbook intentionally doesn't do

- **No code changes to ship to all pods.** The compile experiment runs ONLY in the pod being canary'd, via the SSH-injected env var on the locally-launched python process. The volume's code, the orchestrator's `BOOT_ENV`, and Railway env are all untouched.
- **No defensive in-process fallback (`_eager_transformer` + warmup try/except + `dynamo.reset`).** Reviewer recommended this only for after canary proves compile works. Premature otherwise.
- **No new env flag plumbing** (`LTX_TORCH_COMPILE_EXPERIMENT`). Same reason — that's Phase 3.

If the canary succeeds and we want to scale up, all of those become required changes. They're tracked in the perf plan's Phase 3.
