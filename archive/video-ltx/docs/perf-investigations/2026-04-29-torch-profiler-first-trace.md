# LTX-2.3 perf — torch.profiler first trace
*Reviewer report. Captured 2026-04-29 07:38 UTC. All raw counts/timings extracted from a single Chrome-trace JSON.*

---

## What this report is

Following the Step 3.5 benchmark matrix and the nvidia-smi sampler that
showed apparent "inter-phase gaps" of low SM utilization, we wired
`torch.profiler` into the pod inference path so a single inference can be
captured on demand from the iPad. This report is the first capture: a
single 320×320×49 inference, profiled end-to-end.

The point of the trace is to answer: **what is actually happening during
the windows where SM utilization drops below 100% — kernel-launch
overhead, memory copies, Python control flow, or genuine CPU work?**

The report is intentionally data-heavy and interpretation-light. The
"preliminary interpretation" section at the bottom is one reading; the
reviewer should feel free to draw their own.

---

## Methodology

- **Hardware**: NVIDIA H100 SXM 80 GB HBM3, driver 565.57.01, compute cap 9.0 (Hopper). Single GPU, single inference, no concurrency.
- **Software stack**: CUDA 12.8.1, PyTorch (whatever the Lightricks `ltx-pipelines` upstream pins; nominal 2.x), `runpod/pytorch:1.0.3-cu1281-torch291-ubuntu2404` base, persistent transformer + Gemma + embeddings_processor (Steps 2 + 3 of the LTX perf plan).
- **Inference settings**: 320×320 resolution, 49 frames, 24 fps, BF16 source / FP8 cast quantization (`fp8_cast`), DistilledPipeline two-stage (8 sigmas stage 1 + 3 sigmas stage 2). Random seed.
- **Profiler config**:
  ```python
  torch.profiler.profile(
      activities=[ProfilerActivity.CPU, ProfilerActivity.CUDA],
      record_shapes=True,
      profile_memory=True,   # <-- v1; will be False in next deploy (1 GB trace)
      with_stack=False,
  )
  ```
  Wraps the entire `_run_inference()` body. `_timed()` adds a
  `record_function(<phase_name>)` annotation around each phase, so phase
  boundaries show up as named ranges in the trace.
- **Trace artifact**: `~/Downloads/ltx-profile-073818-320x320x49.json`, 961 MB, 2,569,011 trace events. Available on request.
- **Profiler overhead**: profiled `pipe_total` ≈ 5.95 s vs Step 3.5 baseline of ~3.74 s for the same setting → **~60% overhead** (higher than PyTorch's documented 15–25%, attributable to `profile_memory=True` on a long inference with very high op count). Next capture will drop `profile_memory=True`; expected overhead 15–30%.

### Caveats the reviewer should know

1. **Each phase appears twice** in the raw trace because `_timed()` wraps the synchronous timing AND the `record_function` annotation, so there's an outer span (cuda-synced) and a nested inner span. Tables below show both.
2. **Profiler distorts the absolute numbers.** The proportions and shapes of the data are valid; the absolute pipe_total is inflated. Compare this trace's structure to the unprofiled Step 3.5 baseline numbers, not to itself.
3. **`record_shapes=True` captures input dims**, including matmul (M, N, K). The "Top matmul/attention shapes" table is reliable.
4. **No Python stack frames** (`with_stack=False`). If the reviewer needs Python-level call attribution, we'd need to re-capture with `with_stack=True` (heavier but doable).

---

## Trace summary

| metric | value |
|---|---:|
| Total trace events | 2,569,011 |
| Named phase ranges captured | 20 (10 unique × 2 outer/inner) |
| Total CUDA kernel launches | **224,705** |
| Total GPU kernel time (sum) | 1,732 ms |
| Mean kernel duration | **7.71 µs** |
| Profiled `pipe_total` | ~5,950 ms |
| Step 3.5 baseline `pipe_total` (same setting, unprofiled) | ~3,740 ms |
| Profiler overhead | ~60% (this trace; next will be lower) |

---

## Phase timeline

Relative ms from start of first phase. "Outer" includes the `_timed()`
cuda-sync; "inner" is the underlying call. Caller-visible wall-clock is
"outer".

| phase | start ms | dur ms (outer) | dur ms (inner) |
|---|---:|---:|---:|
| prompt_encoder_build_runtime | 0.0 | 0.1 | 0.1 |
| prompt_encoder_encode | 0.1 | 88.0 | 81.3 |
| embeddings_processor_build_runtime | 89.7 | 0.0 | 0.0 |
| embeddings_processor_run | 89.8 | 34.1 | 32.5 |
| image_conditioner | 124.0 | 511.4 | 340.8 |
| stage_build_runtime | 635.5 | 0.0 | 0.0 |
| stage_1_denoise | 635.5 | 2,574.2 | 2,573.9 |
| upsampler | 3,209.9 | 986.2 | 687.9 |
| image_conditioner | 4,196.2 | 595.9 | 420.8 |
| stage_2_denoise | 4,792.2 | 977.3 | 976.9 |
| stage_teardown | 5,769.6 | 0.0 | 0.0 |
| video_decoder_call | 5,769.7 | 177.8 | 125.9 |

**Inter-phase gaps** (between end of one outer span and start of next): all under 1 ms. No dead time between phases.

---

## CUDA kernel categories (aggregated)

Total GPU kernel time: **1,732 ms**.

| category | calls | total ms | % of GPU time |
|---|---:|---:|---:|
| **memcopy** | 116,568 | **893.2** | **51.6%** |
| **matmul (TensorCore — `nvjet_tst_*` + `cutlass_*` + `flash_fwd_*`)** | 23,528 | **432.1** | **24.9%** |
| **elementwise** | 70,708 | **275.5** | **15.9%** |
| norm (layer_norm + rms_norm) | 10,648 | 55.7 | 3.2% |
| conv (vol2col + slow_conv_dilated3d) | 144 | 47.9 | 2.8% |
| other | 453 | 17.4 | 1.0% |
| reduction | 2,653 | 10.5 | 0.6% |
| scatter_gather | 3 | 0.0 | 0.0% |

---

## Kernel-duration histogram (sample)

Sample is capped at 10,000 per kernel name to avoid OOM during analysis;
proportions hold for the whole population.

| duration bucket | count |
|---|---:|
| <1 µs | 0 |
| 1–5 µs | 88,902 |
| 5–10 µs | 21,580 |
| 10–50 µs | 16,964 |
| 50–100 µs | 2,792 |
| 100–500 µs | 934 |
| 500 µs – 1 ms | 23 |
| ≥ 1 ms | 33 |

Roughly **66% of all kernel launches are sub-5 µs**.

---

## Top 40 CPU ops by total time

| op | calls | total ms | mean µs |
|---|---:|---:|---:|
| `aten::copy_` | 117,692 | 1,377.5 | 11.7 |
| `aten::to` | 49,588 | 1,166.1 | 23.5 |
| `aten::_to_copy` | 40,343 | 1,118.2 | 27.7 |
| `aten::convolution` | 145 | 1,101.5 | 7,596.5 |
| `aten::conv3d` | 144 | 1,101.2 | 7,647.0 |
| `aten::_convolution` | 145 | 1,100.8 | 7,592.0 |
| `aten::slow_conv_dilated3d` | 144 | 1,098.9 | 7,631.4 |
| `aten::fill_` | 77,812 | 612.2 | 7.9 |
| `aten::linear` | 18,710 | 595.2 | 31.8 |
| `aten::addmm` | 18,374 | 403.6 | 22.0 |
| `aten::select` | 174,224 | 382.2 | 2.2 |
| `aten::add` | 26,498 | 227.4 | 8.6 |
| `aten::mul` | 23,677 | 216.0 | 9.1 |
| `aten::scaled_dot_product_attention` | 3,232 | 200.6 | 62.1 |
| `aten::rms_norm` | 10,626 | 196.9 | 18.5 |
| `aten::as_strided` | 303,558 | 190.2 | 0.6 |
| `aten::_fused_rms_norm` | 10,626 | 173.9 | 16.4 |
| `aten::_scaled_dot_product_flash_attention` | 3,168 | 172.5 | 54.5 |
| `aten::empty_strided` | 43,977 | 151.7 | 3.4 |
| `aten::_flash_attention_forward` | 3,168 | 124.1 | 39.2 |
| `aten::transpose` | 53,220 | 115.3 | 2.2 |
| `aten::empty` | 40,535 | 112.0 | 2.8 |
| `aten::reshape` | 47,895 | 103.7 | 2.2 |
| `aten::slice` | 34,862 | 96.1 | 2.8 |
| `aten::unsqueeze` | 33,477 | 81.6 | 2.4 |
| `aten::unbind` | 8,452 | 67.8 | 8.0 |
| `aten::addcmul_` | 8,512 | 65.7 | 7.7 |
| `aten::t` | 18,712 | 63.8 | 3.4 |
| `aten::view` | 85,988 | 59.5 | 0.7 |
| `aten::neg` | 4,352 | 37.7 | 8.7 |
| `aten::sigmoid` | 3,184 | 30.2 | 9.5 |
| `aten::swapaxes` | 8,604 | 27.8 | 3.2 |
| `aten::index` | 28 | 18.2 | 649.5 |
| `aten::empty_like` | 3,334 | 18.1 | 5.4 |
| `aten::ones` | 1,065 | 15.4 | 14.5 |
| `aten::resize_` | 303 | 15.0 | 49.4 |
| `aten::nonzero` | 2 | 14.2 | 7,081.5 |
| `aten::uniform_` | 374 | 13.4 | 35.8 |
| `aten::squeeze` | 6,359 | 13.3 | 2.1 |
| `aten::cat` | 579 | 11.2 | 19.4 |

---

## Top 40 CPU ops by raw call count

(Same data, sorted differently — surfaces what's "spammy".)

| op | calls | total ms | mean µs |
|---|---:|---:|---:|
| `aten::as_strided` | 303,558 | 190.2 | 0.6 |
| `aten::select` | 174,224 | 382.2 | 2.2 |
| `aten::copy_` | 117,692 | 1,377.5 | 11.7 |
| `aten::view` | 85,988 | 59.5 | 0.7 |
| `aten::fill_` | 77,812 | 612.2 | 7.9 |
| `aten::transpose` | 53,220 | 115.3 | 2.2 |
| `aten::to` | 49,588 | 1,166.1 | 23.5 |
| `aten::reshape` | 47,895 | 103.7 | 2.2 |
| `aten::empty_strided` | 43,977 | 151.7 | 3.4 |
| `aten::empty` | 40,535 | 112.0 | 2.8 |
| `aten::_to_copy` | 40,343 | 1,118.2 | 27.7 |
| `aten::slice` | 34,862 | 96.1 | 2.8 |
| `aten::unsqueeze` | 33,477 | 81.6 | 2.4 |
| `aten::add` | 26,498 | 227.4 | 8.6 |
| `aten::mul` | 23,677 | 216.0 | 9.1 |
| `aten::t` | 18,712 | 63.8 | 3.4 |
| `aten::linear` | 18,710 | 595.2 | 31.8 |
| `aten::addmm` | 18,374 | 403.6 | 22.0 |
| `aten::rms_norm` | 10,626 | 196.9 | 18.5 |
| `aten::_fused_rms_norm` | 10,626 | 173.9 | 16.4 |
| `aten::swapaxes` | 8,604 | 27.8 | 3.2 |
| `aten::_reshape_alias` | 8,527 | 7.0 | 0.8 |
| `aten::addcmul_` | 8,512 | 65.7 | 7.7 |
| `aten::unbind` | 8,452 | 67.8 | 8.0 |
| `aten::squeeze` | 6,359 | 13.3 | 2.1 |
| `aten::neg` | 4,352 | 37.7 | 8.7 |
| `aten::empty_like` | 3,334 | 18.1 | 5.4 |
| `aten::scaled_dot_product_attention` | 3,232 | 200.6 | 62.1 |
| `aten::sigmoid` | 3,184 | 30.2 | 9.5 |
| `aten::_scaled_dot_product_flash_attention` | 3,168 | 172.5 | 54.5 |
| `aten::_flash_attention_forward` | 3,168 | 124.1 | 39.2 |
| `aten::item` | 2,491 | 3.7 | 1.5 |

---

## Top 50 CUDA kernels by total GPU time

Long names truncated for readability; full kernel name still searchable in the trace JSON.

| kernel (truncated) | calls | total ms | mean µs | category |
|---|---:|---:|---:|---|
| `at::native::unrolled_elementwise_kernel<direct_copy_kernel_cuda…>` | 29,569 | 715.7 | 24.2 | memcopy |
| `at::native::elementwise_kernel<128, 4, gpu_kernel_impl_nocast<…>>` | 77,197 | 155.5 | 2.0 | memcopy |
| `at::native::elementwise_kernel<128, 4, gpu_kernel_impl_nocast<…>>` | 16,085 | 83.5 | 5.2 | elementwise |
| `nvjet_tst_128x176_64x5_2x1_v_bz_coopA_bias_TNT` | 1,545 | 67.7 | 43.8 | matmul TC |
| `nvjet_tst_64x88_64x11_2x1_v_bz_bias_TNT` | 3,096 | 66.0 | 21.3 | matmul TC |
| `at::native::elementwise_kernel<128, 4, gpu_kernel_impl_nocast<…>>` | 9,677 | 61.9 | 6.4 | elementwise |
| `vectorized_layer_norm_kernel<BFloat16, float, …>` | 10,626 | 55.5 | 5.2 | norm |
| `nvjet_tst_256x128_64x4_1x2_h_bz_coopA_bias_TNT` | 1,113 | 52.3 | 47.0 | matmul TC |
| `at::native::vol2col_kernel<BFloat16>(…)` | 144 | 47.9 | 332.6 | conv |
| `nvjet_tst_24x64_64x16_4x1_v_bz_bias_TNN` | 5,313 | 31.8 | 6.0 | matmul TC |
| `at::native::elementwise_kernel<128, 4, gpu_kernel_impl_nocast<…>>` | 8,512 | 30.6 | 3.6 | elementwise |
| `vectorized_elementwise_kernel<8, CUDAFunctor_add<BFloat16…>>` | 9,701 | 22.4 | 2.3 | elementwise |
| `nvjet_tst_48x64_64x15_2x1_v_bz_bias_TNN` | 1,152 | 18.1 | 15.7 | matmul TC |
| `nvjet_tst_128x240_64x4_2x1_v_bz_coopA_bias_TNT` | 144 | 17.9 | 124.2 | matmul TC |
| `vectorized_elementwise_kernel<8, bfloat16_copy_kernel_cuda…>` | 9,040 | 17.2 | 1.9 | memcopy |
| `nvjet_tst_128x128_64x6_2x1_v_bz_bias_TNT` | 1,097 | 16.7 | 15.2 | matmul TC |
| `nvjet_tst_320x128_64x3_1x2_h_bz_coopB_TNT` | 96 | 14.2 | 148.3 | matmul TC |
| `at::native::elementwise_kernel<…>` | 3,190 | 13.4 | 4.2 | elementwise |
| `pytorch_flash::flash_fwd_kernel<Flash_fwd_kernel_traits<128,128,64,4…>>` | 288 | 13.4 | 46.4 | flash_attn |
| `(anon)::CatArrayBatchedCopy_alignedK_contig<…>` | 1 | 13.3 | 13,322 | other |
| `pytorch_flash::flash_fwd_kernel<Flash_fwd_kernel_traits<64,128,128,4…>>` | 1,440 | 13.1 | 9.1 | flash_attn |
| `nvjet_tst_320x128_64x3_1x2_h_badd_coopB_NNT` | 22 | 13.0 | 589.9 | matmul TC |
| `pytorch_flash::flash_fwd_splitkv_kernel<…128,64,128…>` | 768 | 12.4 | 16.1 | flash_attn |
| `nvjet_tst_64x8_64x16_1x4_h_bz_bias_TNT` | 1,584 | 9.3 | 5.9 | matmul TC |
| `vectorized_elementwise_kernel<8, BinaryFunctor<BFloat16…>>` | 3,238 | 8.9 | 2.7 | elementwise |
| `nvjet_tst_256x128_64x4_1x4_h_bz_coopA_TNT` | 96 | 8.9 | 92.3 | matmul TC |
| `vectorized_elementwise_kernel<8, neg_kernel_cuda…>` | 4,256 | 8.8 | 2.1 | elementwise |
| `nvjet_tst_128x88_64x7_1x2_h_bz_bias_TNT` | 432 | 8.0 | 18.6 | matmul TC |
| `vectorized_elementwise_kernel<8, sigmoid_kernel_cuda…>` | 3,184 | 7.1 | 2.2 | elementwise |
| `nvjet_tst_64x56_64x14_4x1_v_bz_splitK_bias_TNT` | 528 | 7.1 | 13.4 | matmul TC |
| `at::native::elementwise_kernel<128, 2, gpu_kernel_impl_nocast<…>>` | 778 | 7.0 | 9.0 | elementwise |
| `nvjet_tst_64x56_64x14_2x1_v_bz_bias_TNT` | 528 | 6.4 | 12.1 | matmul TC |
| `fmha_cutlassF_bf16_aligned_32x128_gmem_sm80(…)` | 48 | 6.3 | 132.2 | matmul TC |
| `vectorized_elementwise_kernel<8, GeluCUDAKernelImpl…>` | 1,120 | 6.3 | 5.6 | elementwise |
| `nvjet_tst_320x128_64x3_2x1_v_badd_coopB_NNT` | 8 | 6.2 | 775.4 | matmul TC |
| `nvjet_tst_64x8_64x16_1x4_h_bz_splitK_bias_TNT` | 1,152 | 6.1 | 5.3 | matmul TC |
| `vectorized_elementwise_kernel<8, AUnaryFunctor<BFloat16…>>` | 3,211 | 5.8 | 1.8 | elementwise |
| `cublasLt::splitKreduce_kernel<32, 16, int, float, bf16…>` | 2,175 | 5.7 | 2.6 | reduction |
| `pytorch_flash::flash_fwd_splitkv_kernel<…64,64,256,4…>` | 672 | 5.4 | 8.0 | flash_attn |
| `vectorized_elementwise_kernel<8, CUDAFunctorOnSelf_add<BFloat16…>>` | 3,303 | 4.7 | 1.4 | elementwise |
| `unrolled_elementwise_kernel<direct_copy_kernel_cuda…>` (variant 2) | 736 | 4.5 | 6.2 | memcopy |
| `pytorch_flash::flash_fwd_splitkv_combine_kernel<128,64,128…>` | 384 | 4.4 | 11.4 | flash_attn |
| `pytorch_flash::flash_fwd_splitkv_combine_kernel<64,64,256…>` | 672 | 3.0 | 4.5 | flash_attn |
| `pytorch_flash::flash_fwd_splitkv_combine_kernel<128,64,128…>` (variant 2) | 384 | 3.0 | 7.9 | flash_attn |
| `(anon)::CatArrayBatchedCopy<…>` | 192 | 3.0 | 15.6 | other |
| `nvjet_tst_8x64_64x16_4x2_h_bz_splitK_bias_TNN` | 432 | 3.0 | 6.9 | matmul TC |
| `at::native::reduce_kernel<512, 1, ReduceOp<float, MeanOps…>>` | 289 | 2.6 | 8.9 | reduction |
| `at::native::elementwise_kernel<…>` | 114 | 2.5 | 22.0 | elementwise |
| `cutlass_80_tensorop_bf16_s16816gemm_bf16_256x128_64x3_nn_align2` | 13 | 2.3 | 175.1 | matmul TC |
| `nvjet_tst_128x128_64x6_2x1_v_bz_TNT` | 96 | 2.2 | 22.8 | matmul TC |

---

## Top 30 matmul / attention shapes (with `record_shapes=True`)

Pattern: `[batch, tokens, hidden_in] | [hidden_out, hidden_in] | [bias]`. Two clear "model widths" visible: 2048 and 4096 (transformer + Gemma respectively).

| op | input dims | calls | total ms |
|---|---|---:|---:|
| `aten::linear` | `[1, 51, 2048] | [2048, 2048] | [2048]` | 5,280 | 156.5 |
| `aten::addmm` | `[2048] | [51, 2048] | [2048, 2048] | [] | []` | 5,291 | 104.5 |
| `aten::linear` | `[1, 175, 4096] | [4096, 4096] | [4096]` | 2,304 | 67.3 |
| `aten::linear` | `[1, 51, 2048] | [32, 2048] | [32]` | 1,584 | 55.3 |
| `aten::linear` | `[1, 175, 4096] | [32, 4096] | [32]` | 1,152 | 47.1 |
| `aten::addmm` | `[4096] | [175, 4096] | [4096, 4096] | [] | []` | 2,312 | 45.5 |
| `aten::addmm` | `[32] | [51, 2048] | [2048, 32] | [] | []` | 1,584 | 37.9 |
| `aten::linear` | `[1, 175, 4096] | [2048, 4096] | [2048]` | 1,152 | 35.6 |
| `aten::scaled_dot_product_attention` | `[1, 32, 51, 64] | [1, 32, 1024, 64] | [1, 32, 1024, 64] | …` | 528 | 35.3 |
| `aten::addmm` | `[32] | [175, 4096] | [4096, 32] | [] | []` | 1,152 | 34.6 |
| `aten::linear` | `[1, 1024, 4096] | [4096, 4096] | [4096]` | 1,088 | 33.7 |
| `aten::linear` | `[1, 1024, 2048] | [2048, 2048] | [2048]` | 1,088 | 32.7 |
| `aten::_scaled_dot_product_flash_attention` | `[1, 32, 51, 64] | [1, 32, 1024, 64] | [1, 32, 1024, 64] | …` | 528 | 31.9 |
| `aten::scaled_dot_product_attention` | `[1, 32, 51, 64] | [1, 32, 51, 64] | [1, 32, 51, 64] | …` | 528 | 27.8 |
| `aten::scaled_dot_product_attention` | `[1, 32, 175, 128] | [1, 32, 175, 128] | [1, 32, 175, 128] | …` | 384 | 26.9 |
| `aten::scaled_dot_product_attention` | `[1, 32, 175, 128] | [1, 32, 1024, 128] | [1, 32, 1024, 128] | …` | 384 | 25.9 |
| `aten::linear` | `[1, 700, 4096] | [4096, 4096] | [4096]` | 864 | 25.3 |
| `aten::addmm` | `[2048] | [175, 4096] | [4096, 2048] | [] | []` | 1,152 | 24.6 |
| `aten::_scaled_dot_product_flash_attention` | `[1, 32, 51, 64] | [1, 32, 51, 64] | [1, 32, 51, 64] | …` | 528 | 24.1 |
| `aten::_scaled_dot_product_flash_attention` | `[1, 32, 175, 128] | [1, 32, 175, 128] | [1, 32, 175, 128] | …` | 384 | 23.8 |
| `aten::_scaled_dot_product_flash_attention` | `[1, 32, 175, 128] | [1, 32, 1024, 128] | [1, 32, 1024, 128] | …` | 384 | 23.1 |
| `aten::addmm` | `[4096] | [1024, 4096] | [4096, 4096] | [] | []` | 1,088 | 22.6 |
| `aten::scaled_dot_product_attention` | `[1, 32, 175, 64] | [1, 32, 51, 64] | [1, 32, 51, 64] | …` | 384 | 22.4 |
| `aten::addmm` | `[2048] | [1024, 2048] | [2048, 2048] | [] | []` | 1,088 | 22.2 |
| `aten::scaled_dot_product_attention` | `[1, 32, 51, 64] | [1, 32, 175, 64] | [1, 32, 175, 64] | …` | 384 | 20.8 |
| `aten::_scaled_dot_product_flash_attention` | `[1, 32, 175, 64] | [1, 32, 51, 64] | [1, 32, 51, 64] | …` | 384 | 19.7 |
| `aten::linear` | `[1, 51, 8192] | [2048, 8192] | [2048]` | 528 | 19.3 |
| `aten::_scaled_dot_product_flash_attention` | `[1, 32, 51, 64] | [1, 32, 175, 64] | [1, 32, 175, 64] | …` | 384 | 17.9 |
| `aten::linear` | `[1, 700, 4096] | [32, 4096] | [32]` | 432 | 17.8 |
| `aten::linear` | `[1, 51, 2048] | [8192, 2048] | [8192]` | 528 | 17.4 |

Hidden dim 2048, num_heads 32 with head_dim 64 (= 2048) → likely the LTX
transformer denoiser. Hidden dim 4096, num_heads 32 with head_dim 128 (=
4096) → likely Gemma. Sequence lengths 51 / 175 / 700 / 1024 reflect the
(prompt tokens, latent tokens) shapes after embedding.

---

## Background context the reviewer has from prior reports

- **Step 3.5 matrix** (the prior report): full benchmark across 9 (resolution × frames) settings on this same H100 SXM, all at unprofiled baseline. 320×320×49 baseline `pipe_total` = ~3.74 s; 512×512×145 = ~6.3 s. Memory healthy across all settings. Persistent transformer + Gemma + embeddings_processor confirmed working (Steps 2 + 3).
- **nvidia-smi sampler trace** at 100 ms cadence during a 512×512×145 inference: showed SM% pegging at 100% during sustained windows, dropping to 3–50% in between. Power peaked at 681 W (97% of H100 SXM 700 W TDP). Memory bandwidth peaked at 60% during VAE decode; denoise stages ran at 28–41% mem util. We took those low-SM windows to indicate "inter-phase gaps" worth investigating with torch.profiler — the present report addresses that hypothesis.

---

## Preliminary interpretation (one reading; reviewer free to ignore)

This section is the implementer's takeaway — please pressure-test it.

1. **The "inter-phase gap" hypothesis from the nvsmi data was wrong.** Phase boundaries in the trace are within ~0.1 ms of each other; there's no measurable dead time between phases. The "low SM%" windows visible in the nvsmi sampler at the prior report were actually *upsampler + a second image_conditioner running between stage_1 and stage_2 denoise*. Those phases ARE work — they just have lower compute density (smaller models, more memory-bound) than the transformer denoiser. SM% is the wrong metric for that judgement; per-phase work attribution is the right one.

2. **The ~52% of GPU time in `memcopy` kernels is the headline.** `direct_copy_kernel_cuda` alone = 715 ms across 29,569 calls = ~24 µs each. Together with the elementwise category (~16%), **two-thirds of GPU time is overhead between matmuls**. The matmul math itself (Tensor Cores via `nvjet_tst_*` + cutlass + flash_fwd_kernel) is **only 25%** of GPU time. The model is fundamentally **memory- and launch-bound**, not compute-bound.

3. **224k kernel launches with 7.7 µs mean duration** is the symptom. ~66% of launches are <5 µs — each one is dominated by launch overhead, not work. This is exactly the pattern `torch.compile(mode="reduce-overhead")` + CUDA graphs are designed to fix: capture the launch sequence once, replay as a single graph submission. Realistic estimate: **~30–50% of pipe_total recoverable** if the entire pipeline (or even just the denoise + upsampler + decode portions) goes under `torch.compile`.

4. **Tensor Core path IS firing.** ~14k `nvjet_tst_*` (Hopper-family) + cutlass + flash_fwd kernel calls account for the entirety of the matmul category. Switching `fp8_cast` → native `fp8_scaled_mm` would tighten the matmul kernels but is small leverage relative to (3) — probably 50–100 ms of the 432 ms matmul budget at most.

5. **`aten::convolution` (slow_conv_dilated3d) is taking 1.1 s of CPU time.** Only 144 calls. Almost certainly the VAE decoder's 3D conv layers (matches `vol2col_kernel<BFloat16>` 144 calls / 47.9 ms GPU). The kernel is named `slow_conv_dilated3d` — that is literally the slow dispatch path. Worth investigating whether upstream's VAE has a faster conv variant available, or whether it should be replaced with `cudnn` 3D conv. **Independent ~1 s opportunity.**

6. **Profiled ratios should hold across resolutions.** This trace is 320×320×49 (smallest setting in the matrix). At 512×512×145, both the matmul and memcopy categories scale up roughly with token count, but the *ratio* (compute vs overhead) shouldn't change much. The implication: the same `torch.compile` win should apply at every shape in the Step 3.5 matrix, not just this one.

### Optimization ranking from this trace alone

| Action | Estimated pipe_total saving | Effort | Risk |
|---|---:|---|---|
| `torch.compile(mode="reduce-overhead")` on transformer + upsampler | 30–50% (~1.5–2.5 s of 5 s) | medium | medium — compile interacts with persistent models, cancellation hooks, fp8_cast |
| Replace `slow_conv_dilated3d` in VAE decoder with cudnn 3D | up to 1 s (separate) | small if just a flag, large if upstream patch | low |
| Native `fp8_scaled_mm` instead of `fp8_cast` | 50–100 ms | small | small |
| Pre-allocate / reuse intermediate buffers in upsampler/decoder | 100–300 ms (subset of memcopy budget) | medium | low |
| Op fusion (custom Triton) | reduces residual elementwise after compile | large | medium |

---

## Open questions for the reviewer

1. **Is the "slow_conv_dilated3d in VAE" worth chasing independently of `torch.compile`?** The 1.1 s CPU + 47.9 ms GPU on 144 calls suggests CPU dispatch is dominating. Could be a missing cudnn algorithm or an unsupported dilated 3D shape. Reviewer may know the upstream LTX VAE code well enough to say yes/no quickly.
2. **Does `torch.compile` play well with our persistent transformer + Gemma + embeddings_processor across requests?** Our pattern is a single transformer instance reused across many shape-varying inferences. `torch.compile` would re-trace per shape; with shape variation (320–512 px, 49–145 frames) we'd hit recompiles. Worth pre-warming compile for our 7-setting matrix at pod boot? Or accept first-call latency at each new shape?
3. **Which of these would the reviewer want to see in a follow-up trace?**
   - `with_stack=True` — Python frame attribution (heavier, lets us see WHICH Python code is generating the spammy `aten::copy_` calls).
   - A 512×512×145 trace at the high end of the matrix (different work proportions; would confirm or refute item 6).
   - A trace with `torch.compile` already applied to the transformer alone, so we can see the residual non-compile overhead.
4. **Is the FlashAttention path optimal?** We see both `flash_fwd_kernel` (forward) AND `flash_fwd_splitkv_kernel` AND `fmha_cutlassF_bf16_aligned_32x128_gmem_sm80` — three different attention dispatches. The cutlass one is sm_80 (Ampere), not sm_90 (Hopper) — is that suboptimal on H100? Or is it a fallback for a shape FlashAttention doesn't accept?
5. **Does the matmul shape distribution suggest any low-hanging quantization wins?** Most `nvjet_tst_*` kernels here are running at bf16 (the `_TNT` / `_TNN` suffix patterns indicate transpose layouts; `_h884` would be FP16, `_e4m3` would be FP8). We're already on Tensor Cores but in BF16 for many of the matmuls. Would forcing FP8 across more of them via the upstream LTX `fp8_scaled_mm` flag move the needle?

---

## Reproducing this capture

Anyone with iPad access + the deployed pod can reproduce in <2 minutes:

1. Open Settings → Diagnostics → enable "Profile next runs".
2. Trigger one video at the desired shape.
3. SSH-fetch the artifact:
   ```
   ssh root@<pod-ip> -p <port> -i ~/.ssh/id_ed25519 'ls -la /tmp/ltx-profile-*'
   scp -P <port> -i ~/.ssh/id_ed25519 'root@<pod-ip>:/tmp/ltx-profile-<HHMMSS>-<W>x<H>x<F>.json' ~/Downloads/
   ```
4. Open `.json` in [perfetto.dev/#!/](https://perfetto.dev/#!/) for visual inspection.

Implementation lives at commit `61e0e15` (`perf(video): per-request torch.profiler capture toggle`). Profiler config now defaults to `profile_memory=False` after this trace's 1 GB blowup; a fix commit landing shortly.
