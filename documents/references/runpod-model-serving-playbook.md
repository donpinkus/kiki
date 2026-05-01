# RunPod Model Serving Playbook

A reference for getting a new model performant on RunPod, distilled from the LTX-2.3 perf work (April 2026). Read this when:
- Onboarding a new model — image, video, audio, anything heavy
- A pod is slower than expected and you don't know why
- A pod OOMs on a workload that "should fit"
- You're deciding between optimization knobs that look similar

The goal is to short-circuit the rediscovery cost. Most of these lessons cost real iteration time to learn.

---

## Top-level principles

1. **Persistent-model serving is the architecture, not an optimization.** Upstream model libraries (LTX, Diffusers, etc.) ship with a build/use/free lifecycle that loads weights from disk on every request and frees them at the end. That's the right shape for batch processing. For interactive single-tenant serving on a 80 GiB H100 with a 22B model that takes 60+ seconds to load, it's catastrophically wrong. **Build once, hold resident, never free until shutdown.** Treat this as the production architecture.

2. **Storage cache variance dominates first-time numbers.** RunPod hosts vary in host RAM and network-volume throughput. The same pipeline ran ~21s on one US-NE-1 host (file cache hot) and ~127s on another US-NE-1 host (cold network volume reads). The product cannot depend on host luck. **Persistent models eliminate this variance as a side effect.** Don't anchor on a "lucky" measurement.

3. **Measure before you optimize. Measure again after.** Phase timings with CUDA synchronization, plus an `unattributed_ms` tripwire (`pipe_total - sum(named_phases)`), catch measurement bugs immediately. Round 1 had ~8s hidden between phases because `model_context()` was untimed; we'd have shipped the wrong conclusion without the tripwire.

4. **Fail fast; don't silently fall back.** When a persistent model build fails, surface the error on `/health` and let the orchestrator's reaper roll the pod. A "fallback to per-request rebuild" reintroduces 60+s latency invisibly. Better to crashloop than to serve users at 10× latency.

5. **Match the quantization policy to the checkpoint.** `fp8_cast` upcasts FP8 → BF16 per matmul; it's designed to take a BF16 checkpoint and downcast at load time. `fp8_scaled_mm` uses native FP8 matmul with stored per-tensor scales. Pre-quantized FP8 checkpoints have scale tensors that fp8_cast doesn't read, producing numerically valid but garbage output. Read the model card.

6. **Read the upstream `main()` entrypoint before wrapping.** Library authors frequently set up context (`@torch.inference_mode()`, env vars, etc.) in their CLI entrypoint that you'll miss if you only read the public class. We hit this once: missing `torch.inference_mode()` retained autograd buffers on every `fp8_cast` matmul and OOMed an H100 80 GiB on a 14 GiB-resident model.

---

## The persistent-model-mode architecture

This is the change that turned 127s pipelines into 4s pipelines. Apply the same shape to any new model.

### What it looks like

```python
class MyVideoPipeline:
    def __init__(self):
        # Reference handles, set during load()
        self._transformer_ctx = None    # context manager from upstream
        self._transformer = None        # the actual built model
        self._transformer_ready = False
        self._transformer_build_ms = 0
        # ... same shape for every persistent component

    def load(self):
        # 1. Build the upstream pipeline (lazy — usually cheap).
        self.pipe = UpstreamPipeline(...)

        # 2. Build EACH persistent component BEFORE warmup.
        #    Otherwise warmup uses the legacy per-request path and your
        #    metrics will be misleading.
        self._build_persistent_transformer()
        self._build_persistent_text_encoder()
        # ...

        # 3. THEN warmup. Now warmup exercises the persistent serving
        #    path so its timings match steady-state.
        self._warmup()

        self._ready = True

    def _build_persistent_transformer(self):
        # Fail fast: if the build raises, _ready stays False, /health
        # returns the load_error traceback, orchestrator reaps the pod.
        # Do NOT catch and fall back to per-request rebuild.
        t0 = time.time()
        if torch.cuda.is_available():
            torch.cuda.synchronize()
        self._transformer_ctx = self.pipe.stage.model_context()
        self._transformer = self._transformer_ctx.__enter__()
        if torch.cuda.is_available():
            torch.cuda.synchronize()
        self._transformer_build_ms = int((time.time() - t0) * 1000)
        if torch.cuda.is_available():
            self._vram_after_transformer_gb = (
                torch.cuda.memory_allocated() / (1024**3)
            )
        self._transformer_ready = True

    def _run_inference(self, ...):
        # Fail fast: never silently rebuild.
        if self._transformer is None or not self._transformer_ready:
            raise RuntimeError(
                "persistent transformer not initialized — pod should "
                "not have reached _ready=True"
            )
        # Use self._transformer directly. No model_context(), no __exit__().
        ...

    def shutdown_persistent_models(self):
        """Release all persistent components on graceful shutdown.

        Idempotent — tolerates being called zero, one, or many times.
        Releases in reverse build order so dependencies are respected.
        """
        # Each block tolerates already-None refs, clears refs after exit.
        if self._transformer_ctx is not None:
            try:
                self._transformer_ctx.__exit__(None, None, None)
            except Exception as e:
                logger.warning("Error during shutdown: %s", e)
            finally:
                self._transformer_ctx = None
                self._transformer = None
                self._transformer_ready = False
```

### Hooking shutdown

Wire `shutdown_persistent_models()` into the FastAPI lifespan exit, in a thread to avoid blocking the event loop on CUDA cleanup:

```python
@asynccontextmanager
async def lifespan(app):
    try:
        video_pipeline.load()
    except Exception:
        # /health reports the traceback. Don't re-raise — keep the FastAPI
        # app alive so the orchestrator's /health probe can see the error.
        ...
    yield
    # Graceful shutdown: covers `railway up` redeploys + orchestrator-
    # initiated podTerminate within the docker grace window.
    await asyncio.to_thread(video_pipeline.shutdown_persistent_models)
```

### Env kill switches for new persistent paths

When adding persistence to a NEW component, gate it behind an env var (default ON) so you can roll back without a code revert:

```python
if os.getenv("LTX_PERSIST_GEMMA", "1") == "1":
    self._build_persistent_gemma()
else:
    logger.info("LTX_PERSIST_GEMMA=0 — skipping (rebuild per request)")
```

The `_run_inference` path then has two branches: if persistent, use `self._gemma`; otherwise fall back to the legacy build-on-demand path. This keeps both paths working until you've validated the new persistence at scale.

### Keep the lock

A single persistent transformer is single-flight. Don't remove `self._lock` until you've explicitly designed concurrency — sharing one persistent model across two threads will compete for CUDA streams and corrupt mutable internal buffers.

### Memory accounting

`peak_alloc` after persistence always looks "huge" because it includes the resident baseline. Track these separately on every request:

```python
# Captured at start of each inference call:
self._resident_alloc_gb_at_request_start = (
    torch.cuda.memory_allocated() / (1024**3)
)

# Logged at end of call:
peak_alloc = torch.cuda.max_memory_allocated() / (1024**3)
request_peak_delta = peak_alloc - self._resident_alloc_gb_at_request_start

# Plus the absolute triple — peak alone hides allocator fragmentation:
free_b, _ = torch.cuda.mem_get_info()
logger.info(
    "VRAM GiB: peak_alloc=%.2f peak_reserved=%.2f "
    "now_alloc=%.2f now_reserved=%.2f free=%.2f "
    "resident_alloc=%.2f request_peak_delta=%.2f",
    ...
)
```

What to monitor:
- `request_peak_delta` should be **stable** across 10–20 requests. Drift = leak.
- `now_reserved` and `free` should be **stable**. PyTorch's caching allocator can hold reserved-but-unused memory; growth here means fragmentation.
- `peak_alloc` should stay below ~75 GiB on an 80 GiB H100 — leave headroom.

---

## Diagnosis workflow

When a pod is slow or OOMing, walk through these in order. They're sorted by frequency-of-being-the-actual-cause for our LTX work.

### "It's slower than I expected"

1. **Are you measuring with CUDA sync?** If your timer doesn't `torch.cuda.synchronize()` before stop, you're capturing kernel-launch time, not completion time. Per-phase timers will undercount and prior-phase work bleeds into next-phase numbers.

2. **What does `unattributed_ms = pipe_total - sum(named_phases)` say?** If it's >300ms, your phase coverage is broken. We had 8s hidden between phases for an entire round of work.

3. **What's the host's storage/cache state?** Run an I/O benchmark: read the model files to `/dev/null` and time GB/s. <1 GB/s = network-volume cold reads. >3 GB/s = page cache. Sometimes a "slow" pod is just one that hasn't warmed its cache.

4. **Are you rebuilding models per request?** Check whether the per-request `pipe_total` includes time that should be paid once at warmup. If `stage_build` or `prompt_encoder_build` is >1s steady-state, you're paying load cost on every request.

5. **Is the lock contended?** Check `lock_wait_ms`. If a cancelled request is still holding the lock while running to completion, the next request waits ~full pipeline time before starting.

### "It OOMs on a workload that should fit"

1. **Is `torch.inference_mode()` wrapping the call?** `model.eval()` alone is NOT enough. Without `inference_mode`, autograd retains every intermediate buffer (including per-matmul `weight.to(dtype)` upcast tensors) for a possible backward pass. On a 22B model with hundreds of linears, this can balloon by tens of GiB.

2. **Is the quantization policy paired with the right checkpoint?** `fp8_cast` expects a BF16 source and quantizes at load. `fp8_scaled_mm` expects an FP8 checkpoint with scale tensors and uses native FP8 matmul. Wrong pairing = either silent garbage output OR memory bloat from doubled allocations.

3. **What does `now_reserved` look like vs `now_alloc`?** A large reserved-but-not-allocated gap means allocator fragmentation. `PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True` mitigates some cases. Worth trying.

4. **Are you holding model references you forgot about?** In Python it's easy to keep a stale handle in a dict or closure. Check `gc.get_referrers()` on suspected models. If `model.to("meta")` doesn't free as expected, something else is keeping it alive.

5. **Is `request_peak_delta_gb` stable across requests?** If it grows by >100 MiB per call, you're leaking. Look for tensors created inside the inference loop that aren't released.

### "The output is garbage / random noise"

1. **Did you pair the quantization policy with the right checkpoint?** This is the most common cause and produces output that looks structurally invalid (random noise, geometric artifacts). Re-check the model card's table of which quantization mode matches which file.

2. **Are you missing a preprocessing step?** Image conditioning often re-encodes the input (e.g., LTX's `crf=33` JPEG re-encode). Pass `crf=0` or use lossless input formats for sparse line drawings.

3. **Did upstream change their `__call__` flow recently?** If you wrap a private method (`_text_encoder_ctx`, `_embeddings_processor_builder`), confirm signatures haven't changed since your last update.

---

## Measurement infrastructure

### CUDA-synced phase timing

```python
@contextmanager
def _timed(self, name: str):
    """Records CUDA-synced wall-clock for a phase."""
    if torch.cuda.is_available():
        torch.cuda.synchronize()
    t0 = time.perf_counter()
    try:
        yield
    finally:
        if torch.cuda.is_available():
            torch.cuda.synchronize()
        self._inference_timings[name].append(
            int((time.perf_counter() - t0) * 1000)
        )
```

Use lists (not single values) — some phases are called twice per request and you want to see both samples.

### `unattributed_ms` tripwire

After all named phases close:

```python
named_total = sum(
    sum(vs) for name, vs in self._inference_timings.items()
    if name != "pipe_total"
)
unattributed_ms = pipe_total_ms - named_total
self._inference_timings["unattributed"].append(unattributed_ms)
```

Acceptance: under ~300ms or explicitly explained. >300ms = a phase isn't being timed.

**Common gotcha**: `unattributed_ms` can be slightly negative (e.g., -17ms) because nested `cuda.synchronize()` happens twice (inner phase exit, outer total close). Sub-2% slop is normal; don't overfix.

### Health surface

Surface persistent-component state on `/health` so the orchestrator and external monitoring can see what's actually live:

```python
{
    "persistent_transformer_ready": bool,
    "persistent_transformer_build_ms": int,
    "vram_after_transformer_gb": float,
    # ... same triple for every persistent component
}
```

### Where to time `model_context()`

Both the call and `__enter__()` go inside the timer:

```python
# WRONG — model_context() does work at call time, __enter__() is ~free
ctx = pipe.stage.model_context()
with self._timed("stage_build"):
    transformer = ctx.__enter__()    # measured 0ms; real cost hidden

# RIGHT
with self._timed("stage_build"):
    ctx = pipe.stage.model_context()
    transformer = ctx.__enter__()
```

Library authors typically run the heavy work synchronously when the context manager is constructed, then have `__enter__()` just yield the already-built result.

### Rename metrics when their semantics change

When a metric's behavior shifts because of a code change, rename it. We renamed `stage_build` → `stage_build_runtime` after persistence landed: `0ms` then unambiguously meant "no rebuild this request" rather than "no transformer exists." Add a separate field (`persistent_transformer_build_ms`) for the new one-time cost.

---

## Common pitfalls (with fixes)

### `torch.inference_mode()` missing

**Symptom**: OOM on a model that should fit in VRAM by 5×.

**Cause**: `model.eval()` only disables dropout/batchnorm. Autograd still tracks gradients and retains intermediate buffers, including per-matmul upcast tensors. On large models this dominates memory.

**Fix**: Wrap the inference call:

```python
with torch.inference_mode():
    result = self.pipe(...)
```

Lightricks' own `ltx_pipelines.distilled.main()` is decorated with `@torch.inference_mode()`. Most upstream library `main()` functions do the same — check before wrapping.

### `pkill` on a serving pod triggers the orchestrator's reaper

**Symptom**: Pod gets terminated and replaced after a `pkill`, even when the pkill targeted only the python process.

**Cause**: Whether or not `pkill` matches PID 1, killing the python causes `/health` to return 502 during the ~30s python restart. The orchestrator's reaper checks `/health` every 60s; when it finds the pod unhealthy, it terminates and re-provisions. The user's session breaks.

**Fix**: Don't iterate on serving pods. Use a test pod (different name prefix, invisible to the reaper). See `documents/references/pod-operations.md` Task 3 for the full iteration loop.

### `model_context()` timing is misleading

See "Where to time `model_context()`" above. Wrap both `model_context()` AND `__enter__()`.

### `unattributed_ms` slightly negative

Sub-2% precision artifact from nested `cuda.synchronize()`. Don't overfix.

### FP8 checkpoint with `fp8_cast` produces noise

`fp8_cast`'s `Fp8CastLinear.forward()` does `weight.to(dtype)` — no scale applied. FP8 checkpoints store per-tensor `weight_scale` / `input_scale` that the math needs. Use `fp8_scaled_mm` (needs tensorrt-llm) for FP8 checkpoints, OR use the BF16 checkpoint with `fp8_cast` (which downcasts at load).

### Allocator fragmentation OOM despite free memory

Try `PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True` in the pod env. Single CUDA segment grows on demand instead of fixed-size segments fragmenting. Strict improvement in our experience.

### File cache flushed between requests

If `peak_alloc` is fine but you see disk-read-speed (~0.5 GB/s) on a phase that should be RAM-cached, the OS file cache got evicted. Persisting the model in VRAM keeps the disk-backed mapping pinned, helping cache stickiness as a side effect.

---

## RunPod operational knowledge

### Per-DC volumes (architectural mental model)

Network volumes are pinned to one data center. A `scp` to a pod in US-NE-1 only changes US-NE-1's volume; other DCs are unaffected. When the orchestrator rerolls and picks a *different* DC (e.g., excluding a failed one), your scp'd code "disappears" from the next pod's perspective. This is why `npm run deploy` exists: it runs `sync-all-dcs` to fan out to every DC in parallel, so all volumes converge.

For deploy commands and the stock-exhaustion workaround, see `documents/references/pod-operations.md` Task 1. The DCs that recurrently fail at sync time are US-IL-1 + US-NC-1 (image volumes) and US-TX-3 (video volumes) — RunPod stock issue, not a code bug.

### SSH for read-only debugging

For tailing logs, inspecting GPU state, or reading files on a serving pod — see `documents/references/pod-operations.md` Task 8. Quick summary: set `PUBLIC_KEY` on Railway, deploy, terminate the user's pod so a new one provisions with sshd. Use the **"SSH over exposed TCP"** form from RunPod web console (not the proxy `ssh.runpod.io` form, which rejects SCP and non-interactive commands).

The architecture detail worth knowing here (relevant to model-serving debugging, not covered in pod-operations.md): stock `runpod/pytorch`'s entrypoint normally handles SSH setup, but our `BOOT_DOCKER_ARGS` overrides the entrypoint to launch python directly, so the image's SSH bootstrap never runs. We re-implement it inline in `BOOT_DOCKER_ARGS`, gated on `PUBLIC_KEY` so prod pods stay SSH-less by default. Setting `startSsh: true` in the GraphQL input alone is not enough — it exposes port 22 but doesn't actually start sshd.

### Don't iterate by restarting python on a serving pod

For ANY code iteration — scp + pkill + respawn — use a test pod, not a serving pod. The serving pod will be reaped within 60s of `/health` going unresponsive, regardless of how careful you are with the `pkill` pattern. See `documents/references/pod-operations.md` Task 3.

Architecture detail (so you know WHY the test pod path exists): test pods (`kiki-vtest-*` name prefix) are invisible to the orchestrator's prefix-filtered reaper, AND they always have `PUBLIC_KEY` set, which triggers the dev-mode bash respawn loop in `BOOT_DOCKER_ARGS` (`while true; do python3 ...; done`). The combination — no reaper + auto-respawn — is what makes the iteration loop work.

### Crashloop detection

The orchestrator's `waitForHealth` watches `pod.runtime.uptimeInSeconds`. If uptime regresses (container restart), it declares the pod "likely crashlooping" and reaps. This means you can't restart the container at all during the initial `warming_model` window without tripping the reaper.

Once a pod hits `Pod serving — awaiting relay`, the stallMs check is over and brief health check failures are tolerated. Restart is safer at that point — but still triggers `replaceVideoSession` on the relay layer if a WebSocket is open.

### `populate-volume.ts` flow

One-shot script per network volume: spawns an on-demand pod in the volume's DC, mounts the volume, downloads weights into `/workspace/huggingface`, terminates pod. Idempotent — re-running against an already-populated volume just re-checks sizes (HF `snapshot_download` no-ops on cache hit).

For gated models (Gemma terms, Llama terms), `HF_TOKEN` env must be set with the license already accepted at huggingface.co. Pods themselves run `HF_HUB_OFFLINE=1` and never see HF_TOKEN.

---

## Dev iteration loop

Cost per iteration matters. Three regimes:

| Approach | Per-iter cost | When to use |
|---|---:|---|
| `npm run deploy` (full) | 8–10 min | Committed perf changes, anything risky |
| `npm run deploy` (backend-only, flux unchanged) | ~30s | Backend-only changes (orchestrator, etc.) |
| SSH `scp + pkill -x python3` (with respawn loop) | ~3 min (warmup) | Pod-side experiments; reverted if pod was active |

The full deploy goes through `sync-all-dcs` (parallelizes across 11 DCs but slowest DC dominates) then `railway up`. The backend-only fast path is detected automatically by `deploy.ts` reading `.flux-app-version`.

For SSH-based iteration, see CLAUDE.md "SSHing into a running pod (dev iteration only)." Key constraints:
- Pod must be in `Pod serving` state (past warming_model), not initial warmup
- No active WebSocket session (orchestrator's relay watcher will reap on disconnect)
- Use `pkill -x python3`, NOT `pkill -f`
- `BOOT_DOCKER_ARGS` must wrap python in `while true; do ...; sleep 2; done` (respawn loop) — gated by `PUBLIC_KEY` env so prod pods get clean exec

### Useful pod-state commands

```bash
# Live video pod ID + DC + ports
curl -s "https://api.runpod.io/graphql?api_key=$RUNPOD_API_KEY" -d '...' \
  | jq '.data.pod.runtime.ports'

# Pod stdout (RunPod doesn't expose via GraphQL — use web console "Logs" tab,
# or SSH in and `tail -f /tmp/video_server.log` if your launcher redirects)

# Phase timings from latest inference (from anywhere with the pod URL)
curl -s "https://<pod>-8766.proxy.runpod.net/health" | jq
```

---

## Process lessons

These are about how to do this work, not what to build.

### Strict ordering — measure before each speedup change

Without phase-timing instrumentation, "did the optimization help?" is unanswerable. Land the metric BEFORE the change that's supposed to move it. We made the mistake of timing `__enter__()` instead of `model_context()` and shipped a misleading "stage_build = 0" reading; the next pass had to undo and reinterpret.

### Cancellation observability before anything else

Lock-wait time, request-cancellation classification, and `cancelled_but_ran_ms` are critical context for any perf measurement. If a request was queued behind a cancelled job that ran to completion, your "slow request" is actually a queue artifact. Without classifying these, you can't tell.

Three cancel states worth distinguishing:
- `before_start` — cancel arrived before lock acquisition (cheap)
- `during_inference` — cancel arrived mid-pipeline (only achievable with a step-level cancel hook)
- `after_complete` — full inference ran, frames discarded (today's dominant pattern, full pipeline wasted)

### Acceptance criteria are quantitative

Every step should land with a measurable acceptance bar. Examples that worked:
- "`stage_build_runtime ≈ 0ms`"
- "`pipe_total` drops by ~`stage_build` cost"
- "`now_reserved` stable over 10+ requests"
- "`unattributed_ms < 300ms` or explicitly explained"
- "`cancelled_but_ran_ms` p95 `<1.5s`"

"Faster" or "uses less memory" are not acceptance criteria.

### Re-test on the same pod when comparing

Storage cache variance means two runs on different RunPod hosts (even same DC) can be 10× apart. Always test the post-change measurement on the same pod that gave you the pre-change baseline, OR accept that absolute deltas may be noisy and look at structural changes (e.g., `stage_build_runtime` going from 63s to 0).

### Engineer reviews catch what you miss

Two of the most important course corrections in our LTX work came from external review:
- "Your wrapper isn't running under `torch.inference_mode()`" (caused a multi-day OOM detour)
- "fp8_cast is for BF16 checkpoints, not FP8 ones" (caused a noise-output detour)

When you've spent two rounds on a problem, get a second pair of eyes. Especially for memory and numerical correctness, where the failure modes look identical for many root causes.

### Don't dismiss optimizations because they look small

Prompt embedding cache "only" saves ~80ms after persistent Gemma. We dismissed it; reviewer pointed out cache hits today (pre-Gemma persistence) save ~55s. The right reasoning is "what does this save *now*, and is the risk worth it" — not "what does this save in the final state." Restored the cache as a low-risk improvement.

---

## Kiki LTX-2.3 case study (for context)

Concrete numbers from the work that produced this playbook. Useful as a reference when calibrating expectations on a new model.

### Configuration

- **Model**: LTX-2.3 22B distilled, BF16 checkpoint (`Lightricks/LTX-2.3/ltx-2.3-22b-distilled-1.1.safetensors`, 46 GB on disk)
- **Quantization**: `QuantizationPolicy.fp8_cast()` (downcasts BF16 → FP8 at load; ~14 GiB resident)
- **Text encoder**: Gemma-3-12B (`google/gemma-3-12b-it-qat-q4_0-unquantized`, ~24 GB on disk, ~22 GiB resident)
- **GPU**: H100 SXM 80 GB (RunPod single-tenant)
- **Output**: 320×320, 49 frames, 24 fps, two-stage `DistilledPipeline` (8 + 3 sigmas)

### Steady-state `pipe_total` evolution

| Stage | `pipe_total` median | Change | Cumulative |
|---|---:|---:|---:|
| Original (logs 19) — `gpu_model` lifecycle, build per request | 127s | — | — |
| Step 2: persist transformer across requests | 12.3s | −115s (−90%) | −90% |
| Step 3: persist Gemma + embeddings_processor | **3.95s** | −8.4s (−68%) | **−97%** |
| Step 7 (planned): persist VAE encoder + upsampler + decoder | ~2s (target) | −2s | −98% |

### Resident VRAM evolution

| Stage | Resident | Per-request peak delta |
|---|---:|---:|
| Original | ~0.45 GiB (everything freed between phases) | 23 GiB |
| Step 2 (transformer resident) | 18 GiB | 24 GiB |
| Step 3 (transformer + Gemma + EP resident) | 47 GiB | **3.6 GiB** |

The `request_peak_delta` collapse from 23 → 3.6 GiB after Step 3 was the surprise. The transient prompt-stack allocations that drove the per-request peak were exactly the temps allocated during Gemma build and embeddings_processor build. Persisting both eliminated them.

### Pure compute floor

After Step 3, ~47% of `pipe_total` is pure denoising math (1.86s on 4s total). The rest is VAE encoder/decoder lifecycle plus upsampler — all targets for the same persistent-mode treatment in Step 7. The math itself is GPU-bound; further compute-side optimization (`torch.compile`, native `fp8_scaled_mm`) is the deferred Step-9 work.

### Time budget for the full work

- Round 1 (correctness fixes: BF16 checkpoint, `torch.inference_mode`, persistent stage 1+2 within request): ~6 hours
- Round 2 instrumentation + persistent transformer: ~3 hours
- Round 2 persistent Gemma + EP: ~1 hour (architecture established)

Most of round 1 was misdirection (chased OOM theories before noticing missing `inference_mode`). The lesson: when a change is supposed to fix something and doesn't, **stop and re-diagnose** rather than try the next theory. Engineers reviewing logs found both correctness bugs much faster than I did.

---

## Open knobs we haven't pulled yet

Documented for future reference. Order is rough priority for any future model:

1. **Step-level cancellation hook** — fork upstream's denoising loop with `is_cancelled` parameter; raise `CancelledError`; check before AND after each denoiser call.
2. **Backend debounce/coalescing** — hold `video_request` for N ms after a recent `video_cancel` until source is stable.
3. **Persist VAE encoder + upsampler + video decoder** — same architectural pattern, smaller absolute savings.
4. **Prompt embedding cache** — LRU keyed by `(prompt_text, enhance_prompt, model_repo, model_file, text_encoder_repo, app_version)`. Always clone tensors on read.
5. **Stream decoded chunks** — reduce time-to-first-frame; total time barely changes.
6. **Frame reduction** — `n` to `n−8 ≡ 0 mod 8` valid counts; halves temporal latent length.
7. **`torch.compile` on transformer** — kernel fusion; warmup gets longer.
8. **Native FP8 (`fp8_scaled_mm` + TensorRT-LLM)** — Hopper-only; ~10–30% on matmul; needs heavy install.

---

## See also

- `documents/references/provider-config.md` — RunPod ops, pod lifecycle, network volume topology
- `CLAUDE.md` "SSHing into a running pod (dev iteration only)" — the canonical SSH workflow
- `documents/decisions.md` — decision log; 2026-04-23 entry covers the GHCR → volume-entrypoint migration
- `flux-klein-server/video_pipeline.py` — reference implementation of the persistent-model pattern (Steps 0–3 landed)
- `backend/src/modules/orchestrator/orchestrator.ts` — pod lifecycle + cancellation, with the SSH bootstrap in `BOOT_DOCKER_ARGS`
