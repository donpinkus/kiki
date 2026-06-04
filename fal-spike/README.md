# fal.ai validation spike — image realtime path

A self-contained, **throwaway** experiment to decide whether Kiki's real-time
img2img path (FLUX.2-klein) should move from RunPod to **fal Serverless**. We
stand up the image path as a fal private app, measure the things fal's docs can't
tell us, and write a go/no-go verdict at the bottom of this file.

Plan of record: `~/.claude/plans/polymorphic-conjuring-hedgehog.md`.

## Isolation contract (do not violate)

- Everything fal lives in **`fal-spike/`** + the single isolated backend module
  `backend/src/modules/fal_spike/`. Nothing else.
- **No shared imports** between `fal-spike/` and `model-servers/`. `generation.py`
  is a deliberate hand-copy of `model-servers/image/pipeline.py`; if you change
  generation behavior in one, port it to the other by hand.
- The RunPod orchestrator/relay/deploy paths are **untouched**. fal is reachable
  only by running these scripts and (optionally) registering one backend route.
- Deleting fal later = `rm -rf fal-spike/ backend/src/modules/fal_spike/` + remove
  the one `falSpikeTokenRoute` registration line. That's the whole footprint.

## Layout

```
fal-spike/
  image/
    generation.py   self-contained klein pipeline; auto-picks quant by GPU arch
    app.py          fal.App: setup() + /ws (raw, frame-drop) + /realtime (msgpack)
    requirements.txt canonical runner deps (mirror of app.py's `requirements`)
  scripts/
    stage_weights.py @fal.function: pre-download weights onto /data
    bench_stream.py  iPad-substitute WS client: FPS/latency/cold-start/idle probe
  README.md          <- you are here
backend/src/modules/fal_spike/
  token-route.ts     mints short-lived fal JWT from server-side FAL_KEY
```

## Quantization is chosen by the GPU fal gives us

`generation.py::_pick_quant_for_gpu()` selects the transformer overlay from the
detected compute capability (override with `FLUX_FORCE_QUANT`):

| fal GPU       | Arch      | Quant loaded | Checkpoint |
|---------------|-----------|--------------|------------|
| `GPU-RTX5090` | Blackwell | **NVFP4**    | `black-forest-labs/FLUX.2-klein-4b-nvfp4` (BFL official) |
| `GPU-H100`    | Hopper    | **FP8**      | `Photoroom/FLUX.2-klein-4b-fp8-diffusers` *(community — verify!)* |
| `GPU-L40`     | Ada       | **FP8**      | same FP8 repo |
| `GPU-A100`    | Ampere    | **INT8**     | `vistralis/FLUX.2-klein-base-4b-INT8-transformer` *(community — verify!)* |
| (cpu / other) | —         | **BF16**     | base pipeline only |

NVFP4 is only possible on Blackwell. On any overlay failure the pipeline logs a
warning and serves **BF16** rather than crashing.

> **FIRST spike step:** confirm a 4B FP8 (and INT8) checkpoint that actually loads
> into `Flux2KleinPipeline`. BFL's *official* FP8 is the **9B**; the 4B FP8/INT8
> repos above are community/partner conversions. If none load cleanly, either
> quantize the BF16 base → FP8 ourselves, or accept BF16 on H100 and measure that.
> All repos are env-overridable (`FLUX_FP8_REPO`, `FLUX_INT8_REPO`, etc.).

## Prerequisites (Donald — these need your fal account)

1. **fal account + API key.** Create at <https://fal.ai/dashboard/keys>. Then:
   ```bash
   export FAL_KEY="<your-key>"        # also add to backend/.env.local for the token route
   pip install fal fal-client websockets pillow
   ```
2. (Gated checkpoints only) `export HF_TOKEN="<hf-token>"` — the staging function
   forwards it. The 4B klein repos are open today, so likely unneeded.

## Run order

```bash
# 1. Stage weights onto /data (once per quant you want to test).
#    Default stages base BF16 + NVFP4. For the H100 path:
FLUX_STAGE_QUANT=fp8 fal run fal-spike/scripts/stage_weights.py::stage

# 2. Deploy the app. Pick the SKU to test; quant follows from the arch.
#    Try 5090 first; if fal rejects it, fall back to H100.
FAL_MACHINE_TYPE=GPU-RTX5090 fal deploy fal-spike/image/app.py::KikiImageSpike
#    -> note the app id + the wss URL it prints (wss://ws.fal.run/<app-id>/ws)

# 3. (Optional) enable the backend token route to test no-secrets-on-client:
#    register falSpikeTokenRoute (see token-route.ts header), then
#    curl -XPOST localhost:3000/fal-spike/token  -> {token: "..."}

# 4. Benchmark the stream (iPad substitute). 60s @ 2 FPS, then hold idle 120s
#    to probe for an undocumented WS idle cap:
python fal-spike/scripts/bench_stream.py \
  --url wss://ws.fal.run/<app-id>/ws \
  --token "$FAL_TOKEN_OR_KEY" \
  --image <some-sketch>.png --prompt "a watercolor fox" \
  --duration 60 --fps 2 --idle-hold 120

# Baseline comparison against today's RunPod pod (no token):
python fal-spike/scripts/bench_stream.py --url ws://<pod-ip>:8766/ws \
  --image <some-sketch>.png --prompt "a watercolor fox" --duration 60 --fps 2
```

## Questions this spike answers

**Empirical (from the runs above):**
- [ ] Is `GPU-RTX5090` provisionable on fal Serverless, and at what price? (NVFP4 vs re-quantize.)
- [ ] Sustained returned **FPS** for our klein img2img — clears ~1 FPS-out target?
- [ ] **Latency** p50/p90/p99 per frame.
- [ ] **Cold start** to first frame off `/data` vs our ~96s RunPod baseline.
- [ ] **Output quality** of the FP8/INT8 variant vs NVFP4 (eyeball a few results).
- [ ] Does a held-open WS survive minutes idle, or is there a cap → need reconnect?
- [ ] How does fal authorize a raw-WS upgrade to a **private** app? (`--token-mode` ladder in bench_stream.)

**Ask fal directly (not answerable from docs or our runs):**
- [ ] Does an open realtime connection pin a **dedicated** runner for its lifetime,
      or can one runner multiplex connections? (Per-session cost shape; billing is
      per-second of runner lifetime *including* `keep_alive` idle.)
- [ ] Official WS keepalive / idle / max-duration policy.
- [ ] Published per-second rates for RTX-5090 / L40; current 5090 availability.
- [ ] Can the official fal **Swift** realtime client connect to a private app
      (raw-WS or `@fal.realtime`), not just marketplace models?

## Go / no-go gate

**Go** (write a full migration plan) if: klein streams at ≥ target FPS, cold start
≤ ~RunPod today (or maskable with `min_concurrency`), a long WS is stable or cleanly
reconnectable, and per-session cost is within ~1.5× of today's 5090-spot economics.

**No-go / revisit** if: 5090 unavailable *and* H100 klein misses FPS, or WS drops
mid-session with no clean reconnect, or the dedicated-runner cost shape is much worse
at our session profile.

## Status log

- **2026-06-02 — BLOCKED on serverless access.** Provided `FAL_KEY` authenticates
  and works for marketplace inference (queue API) + `fal files` (the `/data`
  surface lists fine). But **custom serverless apps are gated**: both `fal run`
  and `fal deploy` return `Insufficient permissions: Please visit
  https://fal.ai/dashboard/serverless-get-started to request access`. We cannot
  deploy the spike app until that access is granted. **Action (Donald):** request
  serverless access at <https://fal.ai/dashboard/serverless-get-started>, then
  re-run the staging → deploy → benchmark sequence above. (fal CLI 1.75.6 + venv
  at `fal-spike/.venv` already set up.)

## Spike verdict (fill in after running)

> _Date:_
> _GPU used / quant:_
> _Cold start:_     ___s   (RunPod baseline ~96s)
> _Returned FPS:_   ___    (target ≥1 out)
> _Latency p50/p90/p99:_ ___ / ___ / ___ ms
> _WS idle survival:_ ___s before close (or "survived")
> _5090 provisionable?_  yes / no — price ___
> _Output quality vs NVFP4:_
> _fal's answers (cost/runner/Swift):_
>
> **Decision: GO / NO-GO** — reasoning:

## Note on cost

Per project guidance, spike infra cost is negligible (<$100) — don't tear runners
down between iterations to save dollars. The cost questions above are about
launch-scale unit economics, gathered to inform the go/no-go, not to limit spike spend.
