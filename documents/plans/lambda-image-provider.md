# Lambda Cloud image provider (H100) — architecture & rollout plan

**Status (2026-07-15):** Phase 1 built AND benchmarked. Filesystem
`kiki-image-us-southeast-1` is populated (venv 7.3 GB + weights 23 GB). Nothing
deployed; nothing committed to the provisioning path.

**Measured results (gpu_1x_h100_sxm5, us-southeast-1, 2026-07-15):**

| Phase | Measured |
|---|---|
| Launch API call | 4.7 s |
| VM booting → active | **124 s** (dominates; billing starts ~here) |
| active → server responding | ~0 s — cloud-init + venv import + model load **fully overlapped** the VM-boot window; `/health` was `ok` the moment the API reported `active` |
| ready → first frame | 1.1 s |
| **TOTAL launch → first frame** | **130 s** (n=2: setup run went active at 113 s) |
| Pipeline load+warmup (pod-side) | 37.6 s (prefetch 20 s ∥ from_pretrained 22 s + warmup 1.4 s) — vs ~62 s on RunPod 5090 |
| Steady-state frame, 768² 4-step BF16 | **~770 ms** (vs ~1 s 5090-NVFP4, ~250 ms fal 3-step) |

Conclusions: (1) 130 s ≫ the 1-min UX bar → launch-on-user-connect is out, as predicted;
warm pool or fal-bridge-then-migrate is the architecture. (2) The `active` status lags
real readiness — our server is up before Lambda says so; poll `/health` directly, not
instance status. (3) H100 SXM BF16 beats the 5090 NVFP4 path on both load and per-frame
latency. (4) H100 **PCIe had zero capacity** at test time; only SXM ($4.29) in
us-south-2 / us-southeast-1 — capacity, not price, may pick the SKU.

## Why

fal's hosted `flux-2/klein/realtime` gives poor sketch adherence: its conditioning is an
img2img **feedback loop** (`output_feedback_strength` / `schedule_mu`) — the model sees its
own previous output blended with the sketch, not our **reference-mode VAE-concat**
conditioning (sketch latents concatenated with generation latents so the transformer
attends to the sketch directly; `model-servers/image/pipeline.py:55-63`). Running our own
pipeline restores full control: reference conditioning, steps, resolution, prompt handling.
Donald has **$7,500 in Lambda credits** and Lambda stocks H100s.

## What Lambda Cloud actually is (API research, 2026-07-15)

Verified against the live OpenAPI spec (`https://cloud.lambda.ai/api/v1/openapi.json`,
v1.10.0) and docs.lambda.ai. Full details in the spec; the facts that shaped this design:

| Fact | Consequence for us |
|---|---|
| Full VMs, launch/restart/terminate only — **no stop/suspend, no custom images, no snapshots** | Can't pre-bake a booted image. Warm = billing. "Scale to zero" = terminate + full reboot. |
| Boot time officially "**several minutes**"; no SLA | Launch-on-user-connect is off the table for the <1 min UX bar. Measure real p50/p95 ourselves. |
| **Persistent filesystems**: NFS, per-region, launch-time attach only, **multi-attach OK**, ~$0.20/GiB-mo | Same pattern as our RunPod volumes: one populated filesystem per region (weights + venv + app code + boot.sh) serves N instances. |
| **cloud-init `user_data`** on launch (≤1 MB) | Replaces RunPod's `BOOT_DOCKER_ARGS` — boots straight into our server, no SSH needed for serving instances. |
| Public IPv4 per instance; account-global firewall (default: only 22/ICMP); rules apply at boot. **Exception: firewall rules don't apply in us-south-1 — avoid it** | Open TCP 8766 once account-wide; backend connects `ws://<ip>:8766/ws` directly. No TLS proxy like RunPod's — see Security below. |
| Capacity probe: `GET /instance-types` → `regions_with_capacity_available`; launch error `insufficient-capacity` | Pick region at launch time; still handle the race. |
| Rate limits: ~1 req/s; **launch: 1 per 12 s / 5 per min** | No burst-launching a fleet; a future pool scales up gradually. |
| Billing: **per-minute**, starts at health-check pass (≈ `active`), ends at terminate. Cold boot IS billed (unlike fal) | Idle-reaping matters; boot time is a real cost too (pennies — irrelevant vs UX). |
| No spot. `preempted` exists as an instance status (undocumented trigger) — handle defensively | On-demand prices only. |
| H100 PCIe $3.29/hr · H100 SXM $4.29 · GH200 96 GB $2.29 (**ARM** — needs its own venv) · A100 40 GB $1.99 · A6000 $1.09 | klein BF16 needs ~13 GB VRAM — many SKUs fit. H100 PCIe is the default; A100/GH200 are cost fallbacks if per-frame latency allows. |

## GPU/model note: no NVFP4 on H100

H100 is Hopper (SM 9.0); NVFP4 needs Blackwell (SM ≥ 10). `pipeline.py` already detects
this and falls back to BF16 automatically (`pipeline.py:321-339`). Lambda instances run
with `FLUX_USE_NVFP4=0`: BF16 weights only (~13 GB), NVFP4 checkpoint not downloaded.
Per-frame latency on H100-BF16 vs 5090-NVFP4 is an open question the benchmark answers.

## Phase 1 (built) — manual instance + `IMAGE_PROVIDER=lambda` toggle

Goal: A/B sketch adherence fal vs our pipeline, with minimal machinery. One
manually-launched H100 serves Donald's device via the existing relay.

**Scripts** (`backend/scripts/lambda/`, all read `LAMBDA_API_KEY` from repo-root
`.env.local`):

```bash
cd backend
tsx scripts/lambda/capacity.ts                     # who has H100s right now + validate key
tsx scripts/lambda/setup-lambda.ts --region <r> --type gpu_1x_h100_pcie
                                                   # one-time per region: filesystem +
                                                   # venv + BF16 weights + boot.sh
                                                   # (+ pipeline load smoke test on-instance)
tsx scripts/lambda/coldstart-bench.ts --region <r> --keep
                                                   # timed launch → first frame; --keep
                                                   # prints LAMBDA_IMAGE_URL for the backend
tsx scripts/lambda/instances.ts [--terminate-all]  # nothing left billing
```

**Serving instance boot path**: launch API call passes cloud-init `user_data` that writes
`/etc/kiki.env` (per-instance `KIKI_WS_TOKEN`) and `systemd-run`s
`/lambda/nfs/<fs>/kiki/boot.sh` → sources the NFS venv → `exec python3 -u -m image.server`.
Same `image/server.py` as RunPod — same WS protocol, `/health`, `frame_meta`/`queueEmpty`
(video trigger works unchanged).

**Backend toggle**: `IMAGE_PROVIDER=lambda` + `LAMBDA_IMAGE_URL=ws://<ip>:8766/ws?token=…`.
Uses the plain `StreamRelay` (the instance speaks the pod protocol natively). No
provisioning, no fal metering, no RunPod rate-limit recording. If the relay drops:
same-URL reconnect (transient), else error to client — never a RunPod replacement pod.
Changes: `backend/src/config/index.ts` (provider enum + `LAMBDA_IMAGE_URL`),
`backend/src/routes/stream.ts` (fast-path branch + reconnect guard),
`model-servers/image/server.py` (optional `KIKI_WS_TOKEN` query-param gate on `/ws`).

**Security** (differs from RunPod): the instance has a public IP with 8766 open to the
world, so `/ws` requires the per-instance token when `KIKI_WS_TOKEN` is set (unset on
RunPod = unchanged behavior). Traffic is plain `ws://` — acceptable for the dev
comparison; **before any real-user traffic** put TLS in front (Caddy on the instance with
a `<ip>.sslip.io` cert, or restrict the firewall to backend egress IPs). Sketch privacy
constraint (CLAUDE.md #6) applies.

### Benchmark: what decides the architecture

`coldstart-bench.ts` prints this breakdown; the numbers gate Phase 2:

| Phase | RunPod baseline | Lambda expectation |
|---|---|---|
| Launch API → VM active | ~35 s (finding_gpu+creating_pod+image fetch) | **unknown — the critical number** ("several minutes" per docs) |
| active → server responding | ~0 (container) | cloud-init + NFS venv import (unknown; NFS venvs can be slow — if >20 s, copy venv to local NVMe in boot.sh, or tar it) |
| server → model ready | ~62 s (weights→GPU + warmup) | similar; H100 SXM-class bandwidth + page-cache prefetch |
| **Total → first frame** | **~96 s avg / p95 157 s** | if ≲90 s: Lambda ≈ RunPod-class. If >3 min: warm-pool only. |
| Steady-state frame (768², 4 steps) | ~1 s (5090 NVFP4) | unknown (H100 BF16) — also decides if A100/GH200 suffice |

## Capacity & image findings (2026-07-15, day 2)

- **Capacity is volatile on a minutes timescale.** Overnight: 1x H100 SXM in
  us-south-2 + us-southeast-1. By late morning: zero H100 anywhere; A10 in us-east-1
  disappeared in the ~30 min between two script runs (`insufficient-capacity` on a
  type the capacity API had just listed). At one point the ONLY 1x-capacity SKU
  anywhere was none (8x V100 only). Consequences: (a) the Phase 2 pool must treat
  capacity-miss as a first-class path (fal fallback), (b) pre-populated filesystems in
  2-3 regions are cheap insurance (~$5/mo each), (c) a warm instance is also a
  capacity *reservation* — terminating it may mean not getting another for hours.
- **The default OS image differs per region** (us-southeast-1 → 24.04/py3.12,
  us-east-1 → 22.04/py3.10 — inferred from pip's wheel selection when the venv
  build failed on py3.10). ALWAYS pin `image: {family: 'lambda-stack-24-04'}` (or
  gpu-base-24-04) on every launch; the venv on the filesystem is built for py3.12
  and setup-lambda.ts now verifies/rebuilds on mismatch.
- **Boot-time experiments (RESULTS, 2026-07-15 evening, all H100 SXM us-south-2):**
  three runs — lambda-stack ×2, gpu-base ×1 — landed within 1.3 s of each other:
  `/health ok` at **t+180.0 / 180.4 / 181.3 s**, first frame ≈ ready + 1 s.
  (1) **Image family is irrelevant** (gpu-base Δ ≈ −1 s): the ~3 min is Lambda
  host-side provisioning, not image weight. Don't bother with gpu-base.
  (2) **`status: active` lags real readiness by 27–62 s** (207–242 s vs ~180 s ready).
  Poll our `/health` from the moment the IP appears (IP shows up at t+22–31 s,
  during `booting`) — this is the ONLY cold-start lever that worked, and it's free.
  (3) Boot floor moves day-to-day: ~113–130 s (day 1) vs ~180 s (day 2 evening) plus
  an 857 s morning outlier. Treat cold start as 2–3 min p50 with a heavy tail; no
  in-our-control optimization changes it. Warm pool / fal-bridge is confirmed as
  the architecture; further shaving is not worth pursuing.
- **Ops hardening landed in the scripts** (all bit us in one afternoon): launch
  retry-until-capacity (`--retry-mins`, a successful launch IS the reservation —
  the capacity API listing a type does not mean launch will succeed seconds later);
  transient-network-error retry in launch + status polls (local DNS blip killed a
  run); diffusers pinned to `1aadc65` in `model-servers/requirements.txt` (upstream
  main bumped to huggingface-hub>=1.23 on 2026-07-15, unsatisfiable with
  transformers<5 → any fresh venv build failed, RunPod populate included).

## Phase 1.5 (built 2026-07-15) — in-app provider toggle + auto-spun dev H100

Donald can now A/B fal vs Lambda from the iPad without touching Railway:

- **iPad**: Settings → Diagnostics → "Image provider" picker (fal realtime / Lambda
  H100), persisted; a status line shows the pool state. Switching reconnects the
  stream (the provider rides the WS URL). `AppCoordinator.imageProvider`,
  `SettingsPanel.diagnosticsSection`, `AuthService.ensureLambdaPool()`.
- **Per-session override**: stream WS carries `?imageProvider=fal|lambda`; backend
  honors it for JWT-authed **test accounts only** (`isTestAccount` in
  `modules/falBudget`), shadowing `config.IMAGE_PROVIDER` through the whole handler
  (budget gate, relay selection, recovery). `routes/stream.ts`.
- **Dev pool** (`modules/lambda/devPool.ts`): at most ONE `kiki-serve-*` instance.
  `POST /v1/dev/lambda/ensure` (called by iOS at sign-in/app-open and on toggle)
  adopts-or-launches it (capacity-retried 30 min, cloud-init boot, readiness =
  our `/health`, never `status:active`). 30-min idle reaper (touch on every relayed
  frame). WS token = HMAC(LAMBDA_API_KEY, instance name) — deterministic, so backend
  redeploys re-adopt the running instance. If lambda is selected before the instance
  is ready, the stream is bounced with `lambda_not_ready` (never silently served by
  fal — that would corrupt the A/B).
- **Railway env to enable**: `LAMBDA_API_KEY`, `LAMBDA_DEV_POOL_ENABLED=true`
  (+ optional `LAMBDA_REGION`, default us-south-2; `LAMBDA_INSTANCE_TYPE`, default
  gpu_1x_h100_sxm5). `IMAGE_PROVIDER` stays `fal`. The region's filesystem must be
  populated (`scripts/lambda/setup-lambda.ts`). Cost: $4.29/hr while up; worst case
  ~login + 30 min idle per session of use.

## GPU-sharing experiments (2026-07-16, H100 SXM us-south-2, ~$15 of testing)

Two experiment sets: a **multi-user WS load test** against the unmodified
`image/server.py` (1–12 concurrent clients × send modes, 60 s cells,
`scripts/lambda/loadtest.ts`), and an **on-GPU microbench** of batching / steps /
text-encode (`batch-bench.py` over SSH). Raw numbers:
`scratchpad/loadtest-results.txt` (session-local) + the tables below.

### Load test — the current server already time-shares a GPU correctly

| Cell | Result |
|---|---|
| 1 client serial | 1.35 fps, latency p50 716 ms |
| 2–4 clients serial | **aggregate plateaus at 1.76 fps**, split evenly; latency p50 = 1.13 s / 1.70 s / 2.26 s at 2/3/4 clients (≈ 570 ms × N + 150 ms, clean round-robin) |
| 2–8 clients @ 1 fps pace | aggregate 1.76 fps, fairness 1.00 |
| 4 clients @ ⅓ fps pace | demand 1.33 fps **fully served** (everyone gets their 3-second cadence) |
| 8–12 clients @ ⅓ fps | saturates at 1.76 fps, fair split, stable — cadence stretches, nothing breaks |
| Config isolation | **zero violations across all 11 cells** (per-connection prompt/seed state is sound) |

Conclusions: (a) multi-user sharing needs **no pod-side changes** for correctness —
per-connection latest-frame slots + the generation lock behave as a fair round-robin
scheduler; (b) one H100 = **1.76 img/s aggregate** at 4 steps (the raw pipe rate —
server overhead hides under ≥2 concurrent users); (c) user-visible sketch→image
latency ≈ `570 ms × simultaneous_drawers + 150 ms`.

### Microbench — batching is a dead end; steps is the real dial

| Batch (4-step, distinct prompts) | ms/image | throughput vs batch-1 |
|---|---|---|
| 1 | 558 | 1.00× |
| 2 | 798 | **0.70×** |
| 4 | 1396 | **0.40×** |
| 6 | 2163 | **0.26×** |

Naive batching (`prompt=[...], image=[...]`) is **strictly counterproductive**: cost
fits t ≈ 240·N² + 318·N ms — a quadratic term consistent with the reference-mode
conditioning joining batch items in attention sequence space. Making batching work
would need block-diagonal attention masking inside `Flux2KleinPipeline` — model
surgery, not an early lever. Don't pursue without a strong reason.

Steps dial (batch 1): 2 → 341 ms, 3 → 450 ms, 4 → 560 ms (~109 ms/step + ~120 ms
fixed VAE/overhead). **3-step raises the ceiling to ~2.2 img/s (+24%)** and is what
fal runs in production — quality precedent exists. Text-encode is 29 ms/frame —
a per-connection prompt-embedding cache saves ~5%, not worth the complexity now.

### Inference-optimization ladder (2026-07-16, prompted by flux-stream-editor's 64 ms claim)

Tested on H100 SXM against our exact pipeline (768², reference-mode, seed-fixed
quality frames saved to `backend/scripts/lambda/out/ladder/`):

| Config | 4 steps | 3 steps | 2 steps |
|---|---|---|---|
| baseline (stock diffusers SDPA) | 556 ms | 451 ms | 344 ms |
| **+ torch.compile** (max-autotune-no-cudagraphs) | **446 ms** | **366 ms** | **288 ms** |
| SageAttention (SDPA monkeypatch) | 565 ms | — | 348 ms |
| sage + compile | 439 ms | 361 ms | 284 ms |
| cache-dit (Fn=2 on klein's 5 blocks) | 559 ms | — | 346 ms |

- **torch.compile is the only real win: 1.20–1.25×, free, output pixel-identical**
  (seed-fixed diff vs baseline). Compile cost ~80–90 s once at boot — fits inside
  the boot window that already dominates cold start. ADOPT: add to `pipeline.load()`
  behind an env flag (`FLUX_COMPILE=1`) for Lambda instances.
- SageAttention: no observed gain (engagement unverified — shim may have silently
  fallen back; don't re-attempt without profiling first). cache-dit: zero effect —
  with 4 distilled steps there are no similar-enough consecutive steps to skip, and
  its default config doesn't even fit klein's 5-block transformer. The step/block
  caching family (TeaCache/FBCache/Cache-DiT) is structurally inapplicable to
  few-step distilled models.
- flux-stream-editor's "64 ms on H100" was NOT reproduced on our stack; unverified
  what resolution/measurement it refers to. Its remaining untested lever is
  FlashAttention-3 (source build); plausible ~1.1–1.3× more, revisit if economics
  demand it.
- **Temporal caching** ("most of the sketch is unchanged between frames") has no
  clean hook in klein: reference tokens are mixed with generation tokens by joint
  attention at every layer, so nothing survives frame-to-frame except the VAE encode
  (~small) and prompt embeddings (29 ms). The one cheap adjacent win: a
  StreamDiffusion-style **input similarity filter** (skip generation when the
  incoming sketch is unchanged) — server-side, trivial, saves GPU for other users.
- 2-step output is artifact-free on the test sketch (composition differs from 4-step;
  quality subjectively fine) — 2-step+compile = **288 ms/frame = 3.5 img/s/GPU** is
  a legitimate high-throughput mode if Donald approves the look on real drawings.

### Reference-token KV caching — the "streaming flux" path (2026-07-16 evening)

Source-level read of diffusers @1aadc65 (agent-verified, code-cited) + on-GPU tests:

- **diffusers ships `Flux2KleinKVPipeline`** (`pipeline_flux2_klein_kv.py`) +
  `Flux2KVCache`/`kv_cache_mode` in the transformer: reference tokens self-attend
  only and get fixed-t modulation → their per-layer K/V become pure functions of the
  sketch → extracted once (step 0), injected as K/V width for later steps (ref tokens
  leave the sequence: ~45% shorter). The transformer API accepts a HELD cache →
  **cross-frame reuse** (re-extract only when the sketch changes materially) is a
  ~50-line custom pipeline. Cache ≈300 MB bf16.
- **Measured (H100, same seed/sketch/prompt, extract included in every call):**
  base 557/345 ms at 4/2 steps → **kv4b 419/297 ms (1.33×/1.16×)**. Cross-frame
  retention would remove the extract from steady-state too. **Quality on standard 4B
  weights: NOT degraded** (frames in `backend/scripts/lambda/out/kv/` — kv4b output
  is arguably richer; composition differs; sketch-adherence impact unjudged, needs
  real drawings). Composable with torch.compile in principle (untested together).
- **BFL ships KV-trained checkpoints only at 9B** (`FLUX.2-klein-9b-kv` + `-fp8`).
  The repo is GATED and our HF token got 403 — **Donald must accept the license**
  on huggingface.co before the 9B test can run.
- **Batching post-mortem correction:** `pipe(image=[s1..sN])` is N references for ONE
  generation concatenated in sequence (klein.py:537-542) — not batching; our
  "quadratic batching" measured multi-reference mode with cross-contaminated outputs.
  True per-row batching is unimplemented, not impossible — small custom
  `prepare_image_latents` could enable it. Open experiment.
- Base-pipeline exact-reuse inventory (for the "95% unchanged" idea WITHOUT KV mode):
  VAE encode (deterministic argmax), position-ids/RoPE (static per canvas size),
  layer-1 per-token ref K/V per step-index — and nothing deeper (timestep modulation
  hits every token via AdaLN; joint attention mixes ref with gen/text from layer 2).
  Also: `prompt_embeds=` accepted by `__call__` (cache per session); pipeline enforces
  PIL input (docstring claiming latents accepted is false at this commit).
- **Streaming prototype results (2026-07-16 late, real 69-frame angel drawing
  from Insights capture, H100):** baseline 563 ms/frame; kv-per-call 423 ms;
  **held-cache (re-extract every 4th frame) 302 ms median — 1.87× vs prod** —
  mechanically flawless (extract frames 387 ms, cached frames 301 ms, rock
  steady). Cross-frame retention implementation: `scratchpad/kv-stream-proto.py`
  policy C (mirrors kv.py's loop; ~80 lines; needs torch.no_grad — autograd
  retention OOM'd 79 GB before that fix).
- **BUT: KV mode on the standard 4B weights destroys sketch adherence.** On the
  real drawing, baseline picks up the scythe/skull/red accents as they're drawn;
  BOTH stock kv-per-call and held-cache never do (identical failure → not an
  implementation bug). The "temporal stability" of the KV outputs is actually
  weak conditioning — prompt+seed dominate. Consistent with ref tokens neither
  attending to gen/text nor seeing the true timestep on weights never trained
  for that pattern. **KV-on-4B is disqualified for Kiki** (adherence is the whole
  point). Comparison grid: `scratchpad/proto-grid.jpg`.
- **kv9b (trained-for-KV 9B checkpoint, license accepted, weights on NFS):
  697/458 ms per-call at 4/2 steps, 37 GB VRAM.** Cat-sketch output follows
  composition; the decisive angel-sequence adherence test is queued. If 9b-kv
  adheres: held-cache would put it at ~450-500 ms steady-state ≈ baseline-4B
  speed with (possibly) better quality — worth it only if adherence is BETTER
  than baseline-4B, since equal-speed-equal-adherence = no win.
- **kv9b over angel frames (2026-07-16 late): ADHERES — better than baseline-4B.**
  Grid `scratchpad/proto-grid-9b.jpg`: single figure matching the sketch (baseline
  hallucinated a second angel), skull in hand from frame 20, scythe appears as
  drawn, red accents correct, strong frame-to-frame coherence. 705 ms/frame
  per-call at 4 steps (458 at 2 steps), 37 GB VRAM.
- **kv9b held-cache MEASURED (2026-07-17): 551 ms steady-state, extract frames
  681 ms** (4-step, uncompiled). Staleness check on continuous replay looked
  visually indistinguishable (`scratchpad/grid-9b-staleness.jpg`) — **but that
  test masked the real failure mode (Donald, 2026-07-17): draw one line, STOP,
  wait.** Generation is input-driven, so under any every-N refresh policy the
  settled image may NEVER reflect the last stroke — broken core loop. Scheduled/
  lagged refresh policies are REJECTED. Every generated frame must be fresh.
- **Policy consequence:** since every generation follows a sketch change,
  "fresh every frame" makes the simple held-cache worthless in production
  (full extract every frame ≈ per-call, 681–705 ms). The held cache only earns
  its keep via **partial invalidation** (Donald's proposal): recompute only the
  changed tokens (dirty-rect → token indices; scatter-write K/V; stale-unchanged-
  token approximation with periodic full extract for drift). Estimated fresh-
  every-frame cost ~570–590 ms — a ~15–20% win over per-call, contingent on the
  approximation not costing adherence. That experiment (real surgery, ~half-day)
  now decides whether streaming caching ships at all; **per-call 9B (705 ms,
  adherence-best, zero cache machinery) is the safe ship** either way.
- **CONCLUSION — streaming on 9B works end to end:** best-adhering model at
  production speed (551 vs baseline-4B's 563), before compile. Remaining: (1)
  compile-on-9B (~1.2× → ~460 ms est.); (2) fp8 variant for VRAM/speed; (3)
  productize: port held-cache into image/server.py behind a flag with
  delta-triggered re-extract; (4) true per-row batching (independent thread).
  2-step de-prioritized per the locked steps↔adherence rule.
- **FLUX_COMPILE verified end-to-end (2026-07-17):** compiled server through the
  real WS path = **p50 609 ms vs 716 uncompiled (1.18×)**, warmup absorbs 158 s
  (both shapes). us-south-2 filesystem boot.sh + app code updated; us-southeast-1
  still pending the same edit (needs capacity there).

### Ship-now config (Donald-locked, 2026-07-17)

**4 steps + torch.compile + round-robin pool. NOT 3-step:** Donald has observed that
dropping steps weakens sketch adherence on real drawings — adherence outranks
throughput, so the steps dial is off the table for prod (any future steps cut must
prove adherence parity on real drawing sequences, e.g. the angel fixture).
Capacity at 4-step + compile (446 ms/frame → 2.24 img/s/GPU): **6 fully-served
⅓-fps drawers per GPU** (~$0.72/active-drawer-hr), 12–18 connected users/GPU.

**Known issue (backlog, unsolved):** longer text prompts make klein hallucinate away
from the drawing — more text = less sketch influence. Candidate mitigations to explore
on our own pipeline later: prompt truncation/weighting, reference-token upweighting.
Also biases 9B-KV validation: judge its 2-step mode skeptically (steps↓ = adherence↓).

### Capacity & cost model (measured)

Per H100 SXM ($4.29/hr), 768², users capped at 1 frame / 3 s (Donald-approved floor):
- 4 steps: **5 simultaneous active drawers fully served** (1.65 < 1.76 img/s)
- 3 steps: **6–7 simultaneous active drawers** (2.0–2.3 vs 2.2 img/s)
- Active-drawing duty cycle while in-app is realistically 30–50% → **10–15 connected
  users per GPU**, ~$0.30–0.45/connected-user-hour, ~$0.86/active-drawer-hour —
  vs $4.29 at 1:1 and fal's ~$7/attached-hour.
- Overload is graceful (fair split, cadence stretches), so pool sizing is a UX knob,
  not a stability knob.

## Phase 2 (revised with data) — shared pool design

- **Pod**: unchanged for v1 (sharing verified). Optional: 3-step default on Lambda.
- **Backend pool** (generalize `devPool` → registry of N instances):
  - Assignment: new stream → instance with fewest active streams; sticky for the
    session. `frame_meta` relay already `touch()`es per instance.
  - **Scale-up trigger**: per-instance aggregate img/s (frames relayed / sec, EWMA)
    ≥ ~1.5 sustained 3–5 min → launch next instance (arrives ~3 min later; sessions
    rebalance only via new-session assignment, no migration in v1).
  - **Scale-down**: instance with 0 active streams for 20+ min → terminate (keep a
    configurable floor, e.g. 1 during waking hours, 0 overnight — falWarmer-style
    off-window).
  - **fal overflow**: pool full (all instances ≥ target load) or instance booting →
    session serves from fal. Never a hard cliff; capacity-miss on Lambda = more fal
    minutes.
  - Pool state in Redis (survive deploys; instances re-adopted by name prefix +
    deterministic HMAC token, as devPool does today).
- **Before non-test users**: TLS (pinned self-signed cert on the filesystem +
  `StreamRelay` pinning), per-connection user_id log tagging on the pod, and a
  metering decision (count Lambda GPU-seconds against the free tier like fal, or
  price it separately — open question for Donald).

(An earlier speculative Phase 2 sketch lived here; superseded by the measured
"Phase 2 (revised with data)" section above. Two corrections vs that sketch:
one H100 delivers ~1.76 img/s at 4 steps, not ~4 fps; and `server.py` needed NO
per-client queue work — sharing already behaves correctly. Cost sanity still
holds: $7,500 credits ≈ 1,750 H100-SXM-hours.)

## Open questions (Phase 1 answers)

1. Real launch→active p50/p95 per region (run the bench a few times, different hours).
2. NFS venv import + weight-load time vs RunPod NFS (prefetch already in pipeline.py).
3. H100 BF16 per-frame latency at 768²/4-step (vs ~1 s on 5090 NVFP4, ~250 ms on fal
   3-step) — and whether A100 40 GB ($1.99) is adequate.
4. Does `preempted` ever fire on on-demand instances?
5. Adherence: reference-mode VAE-concat vs fal feedback loop, same sketches (the point).

## Launch decisions (Donald, 2026-07-17)

- **Video stays disabled for launch.** (RunPod removal already killed it; this
  makes it a decision, not an accident. Revisit as an LTX-on-Lambda port later.)
- **Lambda metering: per-frame, unified ledger.** Every lambda-delivered frame
  charges $0.001 into the same `monthly_usage` ledger as fal (one $10 free
  tier across providers; ~$0.0007 measured raw GPU cost per 4-step frame,
  rounded up for pool overhead). Batched every 25 frames + flush at close,
  fail-open, same exemptions (test accounts/subscribers), same mid-session
  free_limit_reached cut, live usage pushes to the iPad meter. Session-start
  budget gate now applies to lambda sessions too. Approximate by design —
  the goal is bounding worst-case demo cost near $10/user, not accounting.
- **Lambda quota: assume self-serve headroom for small N.** Formalize with
  Lambda (support ticket / sales) only when approaching ~20 instances.
