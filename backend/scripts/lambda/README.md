# Lambda Cloud scripts — H100 image-provider exploration

Spin up FLUX.2-klein (BF16 — H100 has no FP4) on Lambda Cloud H100s and compare
sketch adherence against fal. Architecture + findings:
`documents/plans/lambda-image-provider.md`.

**Prerequisite:** `LAMBDA_API_KEY=...` in `.env.local` at the repo root
(create a key at https://cloud.lambda.ai/api-keys).

All commands run from `backend/`:

```bash
# 0. Validate key + see live H100 capacity per region (+ anything currently billing)
tsx scripts/lambda/capacity.ts --filter h100

# 1. One-time per region: filesystem + venv + weights + boot.sh (idempotent, ~10-25 min)
tsx scripts/lambda/setup-lambda.ts --region us-east-1 --type gpu_1x_h100_pcie

# 2. Timed cold start: launch → active → server up → model ready → first frame.
#    --keep leaves it running and prints the backend env to point at it:
#      IMAGE_PROVIDER=lambda
#      LAMBDA_IMAGE_URL=ws://<ip>:8766/ws?token=<hex>
tsx scripts/lambda/coldstart-bench.ts --region us-east-1 --type gpu_1x_h100_pcie --keep

# 3. When done comparing — make sure nothing keeps billing ($3.29/hr!)
tsx scripts/lambda/instances.ts --terminate-all
```

Generated frames from the bench land in `scripts/lambda/out/` for eyeballing
adherence (input sketch: `test-sketch.jpg`, override with `--image`).

Also here (run against the DEPLOYED backend, not local):

```bash
# Post-deploy smoke test: mint a test-account JWT and exercise the dev-pool
# endpoints end to end
tsx scripts/lambda/smoke-ensure.ts

# Soak test: N concurrent WS clients on /v1/stream — validates pool failover,
# autoscale, and downgrade-to-fal (see lambda-image-provider.md "Production soak")
tsx scripts/lambda/soak.mts

## Video (LTX-2.3 idle-state animation, dedicated H100)

The video path runs on its own filesystem (`kiki-video-<region>`) and its own
`kiki-video-*` instances — never shared with the image pool (models don't fit
on one 80 GB card together, and image latency must never contend with video).
Architecture + full runbook: `documents/plans/lambda-video-provider.md`.

```bash
# One-time per region: filesystem + video venv + LTX/Gemma weights + boot.sh
# (requires HF_TOKEN in .env.local — Gemma is license-gated)
tsx scripts/lambda/setup-lambda-video.ts --region us-south-2 --retry-mins 30

# Launch the serving instance; prints LAMBDA_VIDEO_URL for the backend
tsx scripts/lambda/launch-video.ts --region us-south-2 --retry-mins 30

# List / stop ($4.29/hr while up!)
tsx scripts/lambda/launch-video.ts --list
tsx scripts/lambda/launch-video.ts --terminate
```
