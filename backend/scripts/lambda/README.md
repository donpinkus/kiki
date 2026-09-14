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

# Provisioning-time probe: launch N bare instances, measure launch-accept →
# status-active / IP / SSH / kernel-boot, terminate. Quantifies Lambda's VM
# provisioning lottery (2.5-14 min observed same region/hour, 2026-08-22) —
# the dominant boot-time variance the hedged launch exists for.
tsx scripts/lambda/boot-probe.mts --n 3 --region us-south-2

# Cold-boot validation: launch ONE serving instance the way the pool does
# (cloud-init → boot.sh off the region filesystem), wait for /health ok,
# print the boot decomposition (provision/os/stack + phase timings), terminate.
# Run after any model-servers boot-path change + filesystem rsync.
tsx scripts/lambda/validate-boot.mts --server video   # or --server image
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

> **Shipping `model-servers/` changes (2026-09-14):** `cd backend && npm run deploy`. That's it — the deploy packs the code into a fleet bundle the backend serves, and every pool instance's boot bootstrap refreshes its region filesystem from it when stale (see `instancePool.userData` + `modules/lambda/fleet.ts`). Running instances keep old code until reaped. `sync-fs.mts` is only an escape hatch now.

> **Adding a region (both pools):** run `setup-lambda.ts --region <r>` and `setup-lambda-video.ts --region <r>`, then add `<r>` to `LAMBDA_REGIONS` on Railway. Order doesn't matter — the pool sweep skips a region until its filesystem exists and no setup box is attached. The setup scripts create the filesystem only at the moment they win capacity (and delete it on a miss), so never pre-create `kiki-image-*` / `kiki-video-*` filesystems by hand: an empty unattached one is exactly what the sweep can't distinguish from a populated one.

## Video (LTX-2.5 Animate screen, dedicated H100)

The video path runs on its own filesystem (`kiki-video-<region>`) and its own
`kiki-video-*` instances — never shared with the image pool (models don't fit
on one 80 GB card together, and image latency must never contend with video).
Architecture + full runbook: `documents/plans/lambda-video-provider.md`.

```bash
# One-time per region: filesystem + video venv + LTX-2.5 split weights (bundled
# Gemma 4) + DFR IC-LoRA + boot.sh. Requires HF_TOKEN in .env.local whose
# account has accepted the LTX-2.x Community License on huggingface.co
# (Lightricks/LTX-2.5 + Lightricks/LTX-2.5-22b-IC-LoRA-Pixel-Spatial-Upscaler
# are auto-gated: a 403 on the .safetensors = not accepted yet). Re-run after
# bumping the ltx-pipelines pin in model-servers/requirements-video.txt.
# --skip-smoke + a non-H100 --type (e.g. gpu_4x_a6000) works for the
# populate alone when no H100 has capacity; the smoke needs an 80 GB card.
tsx scripts/lambda/setup-lambda-video.ts --region us-south-2 --retry-mins 30

# Launch the serving instance; prints LAMBDA_VIDEO_URL for the backend
tsx scripts/lambda/launch-video.ts --region us-south-2 --retry-mins 30

# Quality/latency bench of the serving class on a running instance (per
# pipeline — LTX_PIPELINE is a load-time choice): ssh in, then
#   cd $FS/kiki/app && source $FS/kiki/venv/bin/activate && \
#   HF_HOME=$FS/kiki/huggingface HF_HUB_OFFLINE=1 LTX_PIPELINE=dfr \
#   python3 -m dev.bench_ltx25 --image start.jpg --end-image end.jpg --sizes 512,768,1024 --frames 97
# writes MP4s + summary-<pipeline>.json to /tmp/bench for scp + eyeballing.

# E2E through the DEPLOYED backend, incl. the hosted fal engines (HOSTED=1
# runs wan3 + h3max, ~$1; SKIP_LTX=1 skips the pool phases):
HOSTED=1 JWT_ACCESS_SECRET=... USER_ID=... npx tsx scripts/lambda/validate-animate.mts

# List / stop ($4.29/hr while up!)
tsx scripts/lambda/launch-video.ts --list
tsx scripts/lambda/launch-video.ts --terminate
```
