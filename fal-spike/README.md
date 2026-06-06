# fal.ai hosted realtime — evaluation + ongoing probe

The live img2img path (FLUX.2-klein) runs on **fal's hosted marketplace model**
`fal-ai/flux-2/klein/realtime`, selected by `IMAGE_PROVIDER=fal` on the backend.
This directory holds the evaluation that decided that switch and a probe you can
re-run any time to re-measure latency / quality / protocol against the live
endpoint.

The production code is **not** here — it's `backend/src/modules/fal/falImageRelay.ts`
(a `StreamRelay` drop-in) plus the `IMAGE_PROVIDER` branch in
`backend/src/routes/stream.ts`. The RunPod image path is dormant (revert =
`IMAGE_PROVIDER=runpod` + redeploy). Video idle-state animation stays on RunPod.

> History: an earlier spike tried to deploy *our own* klein pipeline onto fal
> **Serverless** and was blocked on serverless access (2026-06-02). The hosted
> marketplace model needs no serverless access — only a `FAL_KEY` — so we pivoted
> to it. The serverless-app code (`image/app.py`, `generation.py`, etc.) was
> deleted once the hosted path shipped.

## Re-running the probe

```bash
# needs FAL_KEY (in backend/.env.local) and the venv at fal-spike/.venv
cd fal-spike
set -a; . ../backend/.env.local; set +a
.venv/bin/python scripts/bench_hosted_realtime.py --duration 15 --fps 2 --measure-idle
```

`bench_hosted_realtime.py` drives the endpoint through the official
`fal_client.realtime_async` (handles JWT mint + msgpack + URL). It streams a
synthetic sketch at ~2 FPS and reports cold-start, returned FPS, per-frame
latency percentiles, drop ratio, the idle-TIMEOUT window, and saves sample
frames to `/tmp/fal_klein_probe/`. Useful knobs: `--steps`, `--schedule-mu`,
`--feedback` (`output_feedback_strength`), `--image-size`, `--size`/`--quality`
(input JPEG) — sweep these to tune quality.

## Verdict — HOSTED `fal-ai/flux-2/klein/realtime`

> _Date:_ **2026-06-06** (probe + a Node integration test of the real relay)
> _Protocol:_ `wss://fal.run/fal-ai/flux-2/klein/realtime`; **msgpack** messages
>   (encode with `useRecords:false` so fal's Python side decodes them);
>   server-side `Authorization: Key $FAL_KEY` on the WS upgrade — no token mint,
>   no secret on the client.
> _Input msg:_ `{image_url:"data:image/jpeg;base64,…", prompt, num_inference_steps,
>   schedule_mu, output_feedback_strength, image_size, seed, sync_mode:true}`
> _Output msg:_ `{images:[{content:<jpeg bytes>, content_type, height, width}], seed}`
> _Cold start:_ ~1.5s connect→first frame (RunPod baseline ~96s) ✅✅
> _Returned FPS:_ ~2.0 sustained, **0% drop** at 2 FPS in
> _Latency p50/p90/p99:_ 254 / 305 / 323 ms @ steps=3, image_size=square(768)
> _Idle:_ holds ~30s with no input, then `TIMEOUT: no inputs, reconnect when
>   needed` + close. The relay reconnects lazily on the next stroke.
> _Output:_ ~58–64 KB JPEG/frame; quality strong (richly stylized while
>   respecting sketch composition). Conditioning is fal's img2img feedback loop,
>   not our reference-mode VAE-concat — tune `schedule_mu`/`output_feedback_strength`.
> _Cost:_ $0.00194/compute-sec, billed only while actively drawing (iPad dirty-
>   check suppresses idle frames).
>
> **Decision: GO — shipped.** `IMAGE_PROVIDER=fal` in production.
