# LTX-2.3 perf — `torch.compile` Step P2 failure postmortem
*For reviewer. Captured 2026-04-30 ~01:18 UTC. Pods crashlooped on warmup; we rolled back via env flag and reverted to the eager baseline.*

---

## TL;DR

We shipped the reviewer's Step P2 (`torch.compile(mode="reduce-overhead")` over the persistent transformer, gated by `LTX_TORCH_COMPILE=1` in the orchestrator's `BOOT_ENV`). The wrap call returned in 1,272 ms and reported success. **Lowering — which torch.compile defers to the first call to the wrapped model — fired during warmup's `_run_inference()` call, raised, and the exception was not caught by the try/except around the wrap.** The exception propagated out of `_run_inference()` → `load()` → caught by FastAPI's lifespan handler → pod marked itself not-ready → orchestrator's health-based reaper terminated it → new pod provisioned → identical code path → identical failure → infinite crashloop.

**Critical missing data**: we never captured the actual dynamo error message because the pod died mid-warmup before logs flushed. We have logs *up to* the start of Gemma loading but nothing from the warmup-time lowering failure.

We rolled back by flipping `LTX_TORCH_COMPILE` from `'1'` to `'0'` in the orchestrator's `BOOT_ENV` and redeploying. New pods boot with compile off, warm up cleanly, and serve at the prior eager baseline (~3.74 s pipe_total at 320×320×49).

---

## What we shipped

### Pod side: `flux-klein-server/video_pipeline.py`

Added immediately after the persistent transformer build succeeds, *before* warmup:

```python
self._persistent_transformer_ready = True
logger.info(
    "LTX-2.3 persistent transformer ready (%dms, vram_after=%.2f GiB)",
    self._persistent_transformer_build_ms,
    self._vram_after_transformer_gb,
)

# Step P2 — experimental torch.compile pass over the persistent
# transformer. Lowering is lazy: the real compile happens on the
# first transformer(...) call inside warmup, so warmup's
# `warmup_inference_ms` will absorb it.
if os.getenv("LTX_TORCH_COMPILE", "0") == "1":
    logger.info(
        "LTX-2.3 torch.compile transformer (mode=reduce-overhead, "
        "lowering deferred to first call)..."
    )
    t_compile_call = time.time()
    try:
        self._transformer = torch.compile(
            self._transformer,
            mode="reduce-overhead",
            fullgraph=False,
            dynamic=False,
        )
        self._compiled_transformer = True
        self._compile_ms = int((time.time() - t_compile_call) * 1000)
        logger.info(
            "LTX-2.3 torch.compile wrap call returned in %dms "
            "(actual lowering happens at warmup)",
            self._compile_ms,
        )
    except Exception as e:  # noqa: BLE001
        logger.error(
            "torch.compile wrap failed, falling back to eager "
            "transformer: %s", e, exc_info=True,
        )
        # self._transformer remains the eager nn.Module.
        self._compiled_transformer = False
```

The `try/except` only covers the `torch.compile()` wrap call itself. The wrap returns immediately because torch.compile is a lazy wrapper — no actual tracing happens here. **The real work fires later during warmup's first `_run_inference()` call, which is *outside* this try/except.**

The wrap is called at line ~292 of `video_pipeline.py:load()`, then `load()` continues and eventually calls `_run_inference()` at line ~363 for warmup with the warmup image. Warmup is *not* wrapped in any error handler beyond what FastAPI's lifespan catches at the top level.

### Backend / orchestrator side: `backend/src/modules/orchestrator/orchestrator.ts`

Added one entry to the hardcoded `BOOT_ENV` array:

```typescript
const BOOT_ENV: Array<{ key: string; value: string }> = [
  { key: 'HF_HOME', value: '/workspace/huggingface' },
  { key: 'HF_HUB_OFFLINE', value: '1' },
  { key: 'FLUX_HOST', value: '0.0.0.0' },
  { key: 'FLUX_PORT', value: '8766' },
  { key: 'FLUX_USE_NVFP4', value: '1' },
  { key: 'PYTORCH_CUDA_ALLOC_CONF', value: 'expandable_segments:True' },
  { key: 'LTX_TORCH_COMPILE', value: '1' },  // <-- added
];
```

Pod-side code in `video_pipeline.py` reads `os.getenv("LTX_TORCH_COMPILE", "0") == "1"`, so this enables the experiment for every newly-booted video pod after the orchestrator restarted.

---

## Configuration we used

```python
torch.compile(
    self._transformer,
    mode="reduce-overhead",  # CUDA graphs path
    fullgraph=False,         # allow graph breaks; don't require single graph
    dynamic=False,           # fixed shapes only — assume warmup shape persists
)
```

- **`self._transformer`**: the persistent LTX-2.3 transformer object yielded by `pipe.stage.model_context().__enter__()`. This is whatever upstream `ltx_pipelines.DistilledPipeline.stage.model_context()` returns. We did not introspect its type.
- **`mode="reduce-overhead"`**: per the reviewer's recommendation. Uses CUDA graphs to batch the ~224k kernel launches we measured in the first profile.
- **`fullgraph=False`**: chosen defensively so dynamo could fall back to eager on graph breaks instead of raising. (Still raised — see "What we don't know" below.)
- **`dynamic=False`**: chosen because we explicitly wanted one compile per `(width, height, frames)` tuple, not dynamic-shape tracing. The reviewer warned about recompiles on shape change, but we tried compiling for the warmup shape (320×320×49) only.

---

## What happened: observable timeline

From the pod's container logs (logs 30 + 31, attached separately):

| Timestamp (UTC) | Event |
|---|---|
| 2026-04-30 01:16:33 | RunPod creates container `runpod/pytorch:1.0.3-cu1281-torch291-ubuntu2404` |
| 2026-04-30 01:16:34 | Container start |
| 2026-04-30 01:16:42 | Uvicorn server up; `Loading LTX-2.3 ...` |
| 2026-04-30 01:17:38 | Resolved offline checkpoint paths (network volume read complete) |
| 2026-04-30 01:17:38 | LTX pipeline loaded (0.3 s after path resolution) |
| 2026-04-30 01:17:38 | `building persistent transformer (Step 2)...` |
| 2026-04-30 01:17:48 | **`persistent transformer ready (10516ms, vram_after=18.12 GiB)`** ← Step 2 worked |
| 2026-04-30 01:17:48 | **`torch.compile transformer (mode=reduce-overhead, lowering deferred to first call)...`** ← wrap attempted |
| 2026-04-30 01:17:50 | **`torch.compile wrap call returned in 1272ms (actual lowering happens at warmup)`** ← wrap reported success |
| 2026-04-30 01:17:50 | `building persistent Gemma + embeddings_processor (Step 3)...` |
| 2026-04-30 01:17:52 | `Using a slow image processor as use_fast is unset...` (Gemma loading in progress) |
| **(log abruptly ends here)** | |
| 2026-04-30 01:18:09 | Orchestrator's reconcile loop: `[reconcile] orphans found terminating video pod` (podId `jkc73ga3982ayd`) |
| 2026-04-30 01:18:10 | RunPod stop container |
| 2026-04-30 01:18:11 | RunPod remove container |
| 2026-04-30 01:18:22 | Backend redeploy with `LTX_TORCH_COMPILE='0'` SUCCESS — crashloop ends |

### What we observe but didn't directly verify

The pod was killed during or shortly after Gemma loading. The pod's stdout cuts off at "Using a slow image processor..." We did not see:
- "persistent Gemma ready" (would have indicated Step 3 succeeded)
- "persistent embeddings_processor ready"
- "LTX-2.3 warmup..." (the line that immediately precedes the warmup `_run_inference()` call)
- "LTX-2.3 warmup done" or any warmup error

The 18-second gap between the last log line (01:17:52) and container stop (01:18:10) is consistent with: Gemma finishing load (~5 s), embeddings_processor build (~1 s), then warmup starts and `torch.compile` lowering fires on the first transformer forward, raises, exception propagates out of `_run_inference()`, lifespan handler catches it, pod marks itself not-ready. The orchestrator's reaper noticed the not-ready state and terminated the pod 17 seconds after that.

---

## Why my safety net didn't catch it

```python
try:
    self._transformer = torch.compile(...)   # <-- this line returns instantly
    self._compiled_transformer = True
    ...
except Exception as e:
    logger.error("torch.compile wrap failed, falling back to eager: %s", e)
    self._compiled_transformer = False
```

`torch.compile()` is documented as a lazy wrapper. The wrap call constructs the dynamo wrapper object and returns. **No tracing or compilation has happened yet.** The first time the wrapped object is called (in our case: warmup's `transformer(latent, ...)` inside `_run_inference()`), dynamo intercepts the call, traces the forward, sends the trace to inductor, captures CUDA graphs, then runs the captured graph.

That tracing/lowering pipeline is where the failure happened. It's **inside the call to the wrapped model**, not inside the wrap. Our try/except does not cover that call site.

---

## Why this looked like a crashloop

`flux-klein-server/video_server.py` runs the pipeline load inside FastAPI's `lifespan` async context manager. When `video_pipeline.load()` raises during startup, the exception is caught by the lifespan handler — which captures the traceback into `_load_error_traceback` and lets the app continue serving (so `/health` can return diagnostic info instead of refusing connections).

But the pod marks itself not-ready (`video_pipeline.ready == False`). The orchestrator's reconcile loop runs every 60 seconds and terminates pods that are running but not healthy. Once the pod is terminated, the orchestrator's session-aware logic detects there's still an active iPad session that needs a video pod, so it provisions a new one. New pod boots from the same network volume, reads the same `LTX_TORCH_COMPILE=1` env, hits the same lowering failure, dies the same way. **Loop.**

---

## How we recovered

Edited `backend/src/modules/orchestrator/orchestrator.ts`, changed `'1'` to `'0'`:

```typescript
{ key: 'LTX_TORCH_COMPILE', value: '0' },
```

Committed (`a69ca7a`), pushed, ran `railway up` (backend-only — no pod code changed; pod-side env-flag gate was already present and defaulted off, so this flip alone was sufficient with no flux-klein-server resync needed). Backend redeploy SUCCESS at 01:18:22. Next iPad session caused the orchestrator to provision a new pod with `LTX_TORCH_COMPILE=0`. That pod warmed up cleanly, served at the prior eager baseline.

The wrap code itself is still in `video_pipeline.py` — we just don't trigger the path. Reverting the env flag back to `'1'` would re-trigger the same failure.

---

## What we DON'T know (the critical gap)

**We have no record of the actual dynamo error message.** The pod's stdout was streaming via RunPod's container logging; when the pod was killed by the orchestrator-side reaper (a `podTerminate` GraphQL mutation, which sends SIGTERM to the container), there was no log flush window. The dynamo traceback is lost.

Specifically we cannot answer:
- Which op in the LTX transformer's forward pass dynamo couldn't trace.
- Whether the failure was at *trace* time (dynamo's bytecode interception) or *lowering* time (inductor codegen) or *graph capture* time (CUDA graph mode requirements not met).
- Whether `mode="default"` (no CUDA graph requirement) would have succeeded.
- Whether `fullgraph=False` was even respected — possible the error came from a deeper dynamo phase that doesn't have graph-break recovery.

We could re-attempt the experiment with stdout flushing forced (e.g., `python -u`, which we already use; the issue is between the kernel-side write buffer and the orchestrator's terminate-without-grace-period), or with the warmup inference wrapped in our own try/except that explicitly logs+flushes before letting the pod die. **That's the obvious next step if we want the actual error.**

---

## What we tested vs what we changed

| Item | Status |
|---|---|
| LTX-2.3 transformer model | unchanged from working baseline |
| Persistent transformer build (Step 2) | unchanged; logs confirm it built in 10.5 s as before |
| Persistent Gemma build (Step 3) | unchanged; started successfully (last log line) |
| `_run_inference()` body | unchanged (only added profile=False kwarg from earlier; default-off branch is identical to working code) |
| `_timed()` helper | added a `record_function(name)` annotation around the yield. Documented as a no-op when no profiler is active. Has been running on every phase call since 2026-04-29 and worked yesterday with profiler off. |
| `torch.compile` wrap | NEW; this is the change that broke things |
| Orchestrator BOOT_ENV | added `LTX_TORCH_COMPILE='1'` |

The only material change between "working" and "crashlooping" was: the persistent transformer object was wrapped in `torch.compile(mode="reduce-overhead")` before warmup. With that wrap removed (env flag off), behavior is identical to the prior commit.

---

## Background context the reviewer has

- **Original Step P2 plan** ([plan crystalline-squishing-rivest, post-first-trace revision](attached previously)): "Compile only the transformer denoise path (`pipe.stage.run(transformer, ...)`), not the whole pipeline. Use a fixed shape (320×320×49). Pre-warm at pod startup. Failure falls back to eager. Keep an env flag to disable quickly." We implemented all of those except the "failure falls back to eager" — the fallback only covers the *wrap call* failing, not the *lowering* failing.
- **Reviewer's caveats from the prior round** were exactly correct: *"plausible but not proven, may be smaller than estimated, persistent-model + dynamic resolution/frame count can cause recompiles. Start by compiling one stable target shape, not the whole matrix."* We picked the right scope (one fixed shape, transformer only) and still hit a wrap-time failure that took the whole pod down. The lesson is the failure mode wasn't "recompile latency" — it was "compile is impossible for this model in this mode without source changes."
- **What's known about the LTX transformer**: it's the upstream Lightricks `ltx-pipelines` distilled transformer. It uses `fp8_cast` for FP8 quantization, which is a custom op path that wraps each matmul with a BF16 upcast. We don't have source access to the upstream code beyond what's in the venv on the pod. The transformer is built via `pipe.stage.model_context()` — a custom context manager from upstream that yields the model.
- **First profiler trace findings** (320×320×49, eager): 224k kernel launches with mean 7.7 µs duration; 51.6% of GPU time in memcopy kernels; matmul (Tensor Core path firing) only 24.9%. These were the data points that motivated trying `torch.compile` to begin with — the launch histogram strongly suggested a CUDA-graph win was available *if* the model was compilable.

---

## Specific questions for the reviewer

1. **Is `torch.compile(mode="reduce-overhead")` known to fail on FP8-quantized transformers** (or specifically Lightricks' `fp8_cast` path)? If there's a known incompatibility, that's the root cause and the path forward is to either (a) avoid `fp8_cast` and try compile on a BF16 path, or (b) abandon compile and pursue a different launch-overhead reduction (manual op fusion, custom Triton kernels, etc.).

2. **Should we retry with `mode="default"` or `mode="reduce-overhead"` + `fullgraph=False` plus better instrumentation** to capture the dynamo error? `mode="default"` doesn't use CUDA graphs and has weaker constraints — it'd be more likely to succeed but would also recover less of the launch-overhead win. Worth a smoke test.

3. **Is there a recommended way to safely probe whether a model is compilable** before wrapping it in a way that takes down warmup? E.g., a `torch._dynamo.explain()` call we should make at load time, or a fake forward pass with a try/except specifically around the lowering. We need the failure mode to be "log error, fall back to eager, continue" — not "kill the pod."

4. **If `torch.compile` is genuinely a dead end for this model**, what's the next-best lever for the launch-overhead bottleneck? The first profile showed 224k launches at mean 7.7 µs — if we can't fuse them via compile, the alternatives are operator-by-operator manual fusion (huge effort), custom Triton kernels (medium effort, requires identifying hot paths), or accepting eager-mode performance and chasing other bottlenecks (memcopy budget, native FP8). The reviewer's prior recommendation (P3: copy/cast attribution) becomes the next priority if compile is off the table.

5. **Is there any value in capturing the actual dynamo error** before fully pivoting? My instinct is: yes, ~30 minutes of work — wrap warmup in try/except with explicit `logger.error(..., exc_info=True)` and a `sys.stderr.flush()` before the pod dies. That tells us *what* dynamo couldn't handle, which informs whether option 1 / 2 / 4 above is the right pivot. The cost is one more deploy + one more pod boot, no other risk (the env flag still defaults to off, fallback to eager is preserved).

---

## Recommendation (implementer's; reviewer free to override)

Land a tiny defensive fix to `video_pipeline.py` so any future compile experiment can fail loudly without taking down the pod:

```python
# Save the eager reference BEFORE wrapping.
self._transformer_eager = self._transformer
if compile_enabled:
    try:
        self._transformer = torch.compile(self._transformer, ...)
    except Exception as e:
        logger.error("compile wrap failed, eager", exc_info=True)
        self._transformer = self._transformer_eager  # explicit restore

# In load(), wrap warmup specifically:
try:
    self._run_inference(...warmup args...)
except Exception as e:
    if compile_enabled and self._transformer is not self._transformer_eager:
        logger.error(
            "warmup failed under compile; restoring eager and retrying",
            exc_info=True,
        )
        self._transformer = self._transformer_eager
        self._compiled_transformer = False
        # Retry warmup once with eager.
        self._run_inference(...warmup args...)
    else:
        raise  # eager warmup failure is a real bug, don't swallow
```

With that in place we can flip `LTX_TORCH_COMPILE` back on and the worst case is "compile didn't help, log shows why, eager runs." We'd also actually capture the dynamo error.

This is purely defensive scaffolding; no behavior change when compile is off. ~30 lines of code, one commit, one deploy. Then we're free to retry the experiment with `mode="default"` (or any other variant the reviewer suggests) without risking another crashloop.
