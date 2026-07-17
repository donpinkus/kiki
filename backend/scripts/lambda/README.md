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
