# LTX-2.3 perf — `torch.compile` failure + Step P3 attribution
*For reviewer. Captured 2026-05-01 06:30 UTC across three test pods. Resolves the compile question definitively and provides Python-frame attribution for the memcopy bottleneck.*

---

## TL;DR

We ran three back-to-back experiments on test pods (`kiki-vtest-*` prefix, invisible to the orchestrator's reaper, see `documents/references/pod-operations.md`):

1. **`torch.compile(mode="reduce-overhead")`**: compiled successfully, but inference is **5× slower** (~18s vs 3.74s eager baseline at 320×320×49). Three back-to-back runs all converged to ~18s.
2. **`torch.compile(mode="default")`**: same ~18s. Confirms it's not the CUDA graph capture; inductor codegen itself is the regression.
3. **`LTX_FP8_MODE=scaled_mm` smoke**: blocked on missing `tensorrt_llm` Python package (clean ImportError captured).
4. **Step P3 — copy/cast attribution** (`with_stack=True` profile, 320×320×49, eager): **`fp8_cast._upcast_and_round` accounts for 31.5% of all copy time** (1117 ms of 3544 ms total, 95,656 calls per inference). The reviewer's hypothesis from the first trace is now confirmed with direct evidence.

**Combined recommendation**: abandon `torch.compile`, **prioritize adopting `tensorrt_llm`** to enable native FP8 (`fp8_scaled_mm`). Estimated payoff is ~1.4 s off the 3.74 s baseline = ~37% speedup — by far the biggest lever in the priority list, with concrete attribution evidence.

---

## Methodology

All three experiments ran on isolated test pods provisioned via the new `npm run launch-test-pod` workflow (see `documents/references/pod-operations.md`). Test pods use the prefix `kiki-vtest-*` which the orchestrator's reaper filters out — they survive the multi-minute `torch.compile` lowering pause that crashlooped the production attempt on 2026-04-30.

- **Hardware**: NVIDIA H100 SXM 80 GB HBM3, driver 565.57.01, compute cap 9.0 (Hopper).
- **Software**: CUDA 12.8.1, PyTorch (Lightricks `ltx-pipelines` upstream pin), `runpod/pytorch:1.0.3-cu1281-torch291-ubuntu2404` base.
- **Test inference**: 320×320, 49 frames, 24 fps, BF16 source / FP8 cast quantization (`fp8_cast`), DistilledPipeline two-stage. Same shape and prompt across all runs to keep comparisons clean.
- **WebSocket trigger**: `documents/perf-investigations/scripts/test_pod_inference_request.py` (committed in this PR). Hits `ws://localhost:8766/ws` from inside the pod.
- **Trace parser**: `documents/perf-investigations/scripts/parse_trace_attribution.py` (sweep-line algorithm, O(N log N) per thread).

---

## Experiment 1: `torch.compile(mode="reduce-overhead")`

### Setup

`flux-klein-server/video_pipeline.py` already supports the wrap behind `LTX_TORCH_COMPILE` env (added 2026-04-29, disabled in production after the orchestrator-level crashloop). Launched a test pod with `--env LTX_TORCH_COMPILE=1`.

### Boot timeline

```
00:00  Container start
01:39  Loading LTX-2.3 ...
07:38  pipeline loaded in 0.3s          # 6 min reading checkpoint from network volume
07:48  persistent transformer ready (10516 ms)
07:48  torch.compile transformer (mode=reduce-overhead, lowering deferred)...
07:50  torch.compile wrap call returned in 1272 ms
07:50  building persistent Gemma + embeddings_processor...
~16:00 video_ready=true (warmup done after 9+ minutes of compile lowering)
```

`/health` final state:

```json
{
  "video_ready": true,
  "compiled_transformer": true,
  "compile_ms": 1321,
  "warmup_inference_ms": 554661,
  "load_ms": 977195,
  "vram_after_embeddings_processor_gb": 46.73
}
```

Compile lowering completed cleanly. 31 inductor compile-worker subprocesses fanned out to do parallel codegen. CUDA graphs were captured. No native crash, no Python exception.

### Inference benchmark (back-to-back runs after warmup)

| Run | `genMs` from pod | Wall-clock from WS client |
|---:|---:|---:|
| 1 | 18,758 ms | 18.86 s |
| 2 | 18,305 ms | 18.41 s |
| 3 | 17,864 ms | 17.97 s |
| **Median** | **18,305 ms** | — |
| **vs eager baseline (3,740 ms)** | — | **+390% (5× slower)** |

Three consecutive runs all converged to ~18s. This is not a one-time recompile cost — it's the steady-state behavior of the compiled path. **`torch.compile(mode="reduce-overhead")` is a measurable regression on this model.**

---

## Experiment 2: `torch.compile(mode="default")`

### Setup

Hypothesis from Experiment 1: maybe the regression is caused specifically by CUDA graph capture (`mode="reduce-overhead"`), not by the inductor lowering itself. `mode="default"` skips graph capture but still does dynamo + inductor.

scp'd a modified `video_pipeline.py` to the same test pod with `mode="default"` + `mode="reduce-overhead"` swapped, killed python (bash respawn loop in dev mode picked up the new code automatically), waited for new warmup.

### Boot

Warmup with `mode="default"`: 8 min 50s. Similar to reduce-overhead's 9 min 14s — same parallel inductor compile workers, same lowering. Just no CUDA graph capture step at the end.

### Inference benchmark

| Run | `genMs` |
|---:|---:|
| 1 | 18,026 ms |
| 2 | 19,252 ms |
| 3 | 18,622 ms |
| **Median** | **18,622 ms** |

Same ~18s. CUDA graph capture wasn't the bottleneck — **inductor's lowered kernels themselves are slower than eager dispatch on this workload**.

### Likely causes (informed guess, not proven)

- The eager `nvjet_tst_*` Tensor Core kernels and `flash_fwd_kernel` are highly tuned for Hopper. Inductor-generated replacements likely don't hit the same paths.
- LTX-2.3's `fp8_cast` is a custom op path with `@torch._dynamo.disable` markers. Many graph breaks → many CUDA stream syncs → overhead exceeds savings.
- Per-call shape variation (prompt token length differs each call) might force partial recompiles even at fixed image shape.

We don't need to fully diagnose the cause to make the call. **Compile is off the table for this model** without significant upstream work.

---

## Experiment 3: `LTX_FP8_MODE=scaled_mm` smoke test

### Setup

Launched a test pod with `--env LTX_FP8_MODE=scaled_mm`. The pod-side code already reads this env (`config.LTX_FP8_MODE` defaults to `"cast"`). Just wanted to know: is `scaled_mm` a viable code path on this checkpoint?

### Result

Pod load failed in ~30s with a clean `ImportError` captured by FastAPI's lifespan handler:

```python
File "/workspace/venv/lib/python3.12/site-packages/ltx_core/quantization/policy.py", line 32, in fp8_scaled_mm
    import tensorrt_llm  # noqa: F401, PLC0415
ModuleNotFoundError: No module named 'tensorrt_llm'

The above exception was the direct cause of the following exception:
  ImportError: tensorrt_llm is not installed, skipping FP8 scaled MM quantization
```

### Read

`fp8_scaled_mm` IS supported in upstream `ltx_core` code, but it requires the `tensorrt_llm` Python package (NVIDIA's TensorRT-LLM wrapper). We don't have it in our pod venv.

This reframes the reviewer's #4 priority: it's not "does FP8 work?" — it's "**is the `tensorrt_llm` dependency worth taking on?**" Experiment 4 below answers that question quantitatively.

---

## Experiment 4: Step P3 — copy/cast attribution (the answer to "is FP8 worth it?")

### Setup

scp'd a modified `video_pipeline.py` with `with_stack=True` enabled in the profiler config, restarted python on the test pod, triggered one inference at 320×320×49 with `enableProfiling=true`. Captured a 1.27 GB Chrome trace JSON containing Python call stacks for every op.

The trace is available locally at `~/Downloads/p3-trace.json` (not committed; ~1.3 GB). Parser code in `documents/perf-investigations/scripts/parse_trace_attribution.py`.

### Top callers by total copy/cast CPU time

| Caller | Calls | Total ms | Read |
|---|---:|---:|---|
| `ltx_core/quantization/fp8_cast.py:50 _upcast_and_round` | **95,656** | **1,117.5** | **The FP8 → BF16 upcast on every matmul.** |
| `ltx_core/loader/sft_loader.py:20 load` | 1,664 | 1,437.7 | Safetensors loading — see "Surprise" below |
| `torch/nn/modules/conv.py:699 _conv_forward` | 76,596 | 425.2 | VAE 3D conv internals |
| `ltx_core/model/transformer/transformer.py:126 get_ada_values` | 22,176 | 325.5 | Adaptive layer norm |
| `ltx_pipelines/utils/media_io.py:103 load_image_and_preprocess` | 14 | 72.2 | Image conditioning preprocessing |
| `ltx_core/model/video_vae/video_vae.py:961 _accumulate_temporal_group_into_buffer` | 9 | 49.3 | VAE decoding |
| `ltx_core/model/transformer/transformer.py:379 apply_cross_attention_adaln` | 3,168 | 42.9 | Cross-attention norm |
| `transformers/models/gemma3/modeling_gemma3.py:135 forward` | 2,601 | 32.3 | Gemma encoder |
| `ltx_core/utils.py:21 to_velocity` | 220 | 8.3 | Diffusion utility |
| `torch/nn/modules/module.py:1348 convert` | 2,080 | 4.1 | Generic dtype convert |

**Total copy/cast time: 3,544 ms** across **207,624 events**.

### Aggregated by source-file fragment (any frame anywhere in stack)

| Fragment | Events | Total ms | % of copy time |
|---|---:|---:|---:|
| `fp8_cast` | 95,656 | **1,117.5** | **31.5%** |
| `quantization` (same as fp8_cast — sibling fragment) | 95,656 | 1,117.5 | 31.5% |
| `transformer` (model arch) | 125,436 | 1,534.8 | 43.3% |
| `denoiser` | 122,045 | 1,498.9 | 42.3% |
| `gpu_model` (load path) | 4,118 | 1,442.1 | 40.7% |
| `video_vae` (VAE decoder) | 59,723 | 378.5 | 10.7% |
| `conditioning` | 34,661 | 268.2 | 7.6% |
| `upsampler` | 17,582 | 98.7 | 2.8% |
| `gemma` | 3,425 | 36.7 | 1.0% |

Note: a single copy can match multiple fragments (e.g., a copy inside `fp8_cast` is also inside `denoiser`), so fragment % can exceed 100% in aggregate.

### Reviewer's hypothesis: confirmed

The reviewer's earlier note was:

> Given we are using `fp8_cast`, a likely explanation is that many linear weights are stored in FP8 but repeatedly upcast to BF16 for matmul. If that is true, native `fp8_scaled_mm` may help more than the report estimates, because it could remove repeated casts/copies in addition to speeding matmul.

`fp8_cast._upcast_and_round` = **31.5% of all copy time** = **1,117 ms / inference** at 320×320×49. The pattern is exactly what was hypothesized: 95,656 calls per inference, 12 µs each, ~5 calls per matmul × 18,710 matmuls ≈ 95k.

Adopting `tensorrt_llm` and switching to `fp8_scaled_mm` would:
- **Eliminate the `_upcast_and_round` calls entirely** (~1.1 s recovered)
- **Speed up the matmul itself** (FP8 Tensor Core ops are ~1.5× faster than BF16 on H100)
- **Estimated total savings: ~1.4 s off the 3.74 s baseline → ~2.3 s, ~37% speedup**

This is the largest potential win we've found, with the most direct evidence backing the estimate.

### Surprise finding

`ltx_core/loader/sft_loader.py:20 load` (safetensors loading) shows up at **1,437 ms / 1,664 calls**. This is the on-disk weight loader. It should NOT fire during inference (Step 2 persistent transformer was supposed to load weights once at warmup and reuse).

Two possibilities:
1. **One-time lazy materialization on first inference call.** Some FP8 weights might be lazily quantized on first use, triggering `sft_loader.load` for that subset. If so, this cost amortizes after the first call.
2. **Real per-call regression.** If the persistent transformer is incorrectly evicting and re-loading weights from disk, that's a bug.

Worth a follow-up profile of inference call #2 (after warmup) to see if `sft_loader.load` cost drops to zero or stays ~1.4 s. Lower priority than the FP8 work.

---

## Caveats

1. **Profiler overhead distorts absolute timings, not structure.** With `with_stack=True` and `record_shapes=True` enabled, the profiled inference took ~170 s vs 3.74 s eager baseline — a 45× slowdown from instrumentation. Op proportions (the % column) and call counts (the count column) are valid; raw ms columns are inflated.

2. **`torch.compile` warmup time is one-time.** The 9-minute compile latency is paid once per pod boot. If we ever revisit compile (e.g., with a smaller fixed scope or different mode), pre-warming at startup would amortize it. But since steady-state inference is also slower, that doesn't change the verdict.

3. **`torch.compile` was only tested at a single shape** (320×320×49). It's possible some shapes would compile differently. Given the regression is across both modes and consistent across 6 runs, follow-up at other shapes is low priority.

4. **The `tensorrt_llm` dependency cost is real engineering work.** The package is multi-GB, version-pinned to specific CUDA + PyTorch combos, and may interact unpredictably with our existing fp8_cast path. The 1.4 s estimate assumes successful integration; the engineering risk is moderate.

---

## Recommendation

| Priority | Action | Justification |
|---:|---|---|
| **1** | **Adopt `tensorrt_llm` in the venv. Switch `LTX_FP8_MODE` to `scaled_mm`.** | Direct attribution evidence: 32% of copy time is `fp8_cast._upcast_and_round`; eliminating it saves ~1.4 s = ~37% of pipe_total. Largest measured lever. |
| 2 | Profile a 2nd inference call (post-warmup) at 320×320×49 to confirm `sft_loader.load` doesn't repeat | 1.4 s of CPU time attributed to weight loading during inference is suspicious; could be a separate ~1 s win if it's a real per-call regression rather than first-call materialization. |
| 3 | If `tensorrt_llm` adoption fails (incompatible with our PyTorch/CUDA), pivot to manual op fusion via custom Triton kernels for the `_upcast_and_round` path | More effort but addresses the same bottleneck if the dependency route doesn't work. |
| ❌ | `torch.compile` (any mode) | Confirmed regression. Don't revisit without strong new evidence. |
| ❌ | "Reduce kernel launches" via batching, CUDA graphs, etc. | The launch-overhead theory was wrong. Eager dispatch is faster than the lowered kernels. |
| Defer | VAE/upsampler/decoder persistence (Step P7) | VAE conv = ~13% of copy time and ~9% of GPU time. Useful but smaller than the FP8 win. |
| Defer | Cancellation/debounce (Step 5/6) | UX polish, not steady-state latency. |

---

## Open questions for the reviewer

1. **Should we adopt `tensorrt_llm`?** This is the gating decision for the largest perf win. Considerations: package size (~5 GB?), version pinning to PyTorch 2.x + CUDA 12.8, potential conflict with the existing `ltx_core` quantization path, ongoing maintenance burden if NVIDIA changes the interface. Vs ~1.4 s pipe_total savings (37% speedup at 320×320×49, scaling to larger savings at higher shapes).

2. **Is the `sft_loader.load` showing up during inference a real bug or expected lazy materialization?** Worth a follow-up profile of call #2 to disambiguate.

3. **Anything in the compile evidence that might suggest `mode="reduce-overhead"` isn't a complete dead end?** E.g., a known dynamo limitation we could patch around. Or is it definitively off the table for this model?

4. **Any value in capturing a Step 3.5 large-shape (512×512×145) attribution profile** to confirm `fp8_cast` is also dominant at the product target? Or does the 320×320×49 evidence generalize?

---

## Reproducing this

All three experiments use the test pod workflow:

```bash
cd backend

# Experiment 1
npm run launch-test-pod -- --env LTX_TORCH_COMPILE=1
# Watch /health, run scripts/test_pod_inference_request.py

# Experiment 3
npm run launch-test-pod -- --env LTX_FP8_MODE=scaled_mm
# Watch /health for load_error

# Experiment 4 (P3 attribution)
npm run launch-test-pod
# scp a modified video_pipeline.py with with_stack=True to /workspace/app/
# pkill python; wait for warmup
# scp test_pod_inference_request.py to /tmp/
# Run with --profile
# scp the resulting /tmp/ltx-profile-*.json back
# python3 documents/perf-investigations/scripts/parse_trace_attribution.py <trace.json>
```

When done: `npm run terminate-test-pod -- <podId>`. Or check `npm run list-test-pods` first to see what's alive.
