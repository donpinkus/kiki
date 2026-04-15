# Pre-baked FLUX.2-klein server image.
#
# Contains: torch 2.9.1 + cu128 (from base), diffusers from git, the full
# FLUX.2-klein-4B BF16 safetensors tree (~13 GB), BFL's NVFP4 transformer
# weights (~7 GB), and the server.py entrypoint.
#
# Goal: cold start at ~60-90s (pod pull + server start + warmup) instead of
# the 3-5 min that setup-flux-klein.sh took.
#
# Published via .github/workflows/build-flux-image.yml to ghcr.io.

FROM runpod/pytorch:1.0.3-cu1281-torch291-ubuntu2404

ENV DEBIAN_FRONTEND=noninteractive
ENV HF_HOME=/opt/huggingface
ENV HF_HUB_DISABLE_TELEMETRY=1

# ─── Layer 1: OS deps ───────────────────────────────────────────────────
# git is needed to pip-install diffusers from source.
RUN apt-get update \
 && apt-get install -y --no-install-recommends git \
 && rm -rf /var/lib/apt/lists/*

# ─── Layer 2: Python deps ───────────────────────────────────────────────
# requirements.txt is small and changes rarely; kept near the bottom of the
# stack so edits to server.py don't invalidate it.
COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt \
 && rm /tmp/requirements.txt

# ─── Layer 3: FLUX.2-klein-4B BF16 weights (~13 GB) ─────────────────────
# allow_patterns is critical — the HF repo has multiple transformer variants
# (fp8, bnb, etc.). Without the allowlist we'd pull all of them (~40 GB).
ARG FLUX_MODEL_REV=main
RUN python -c "\
from huggingface_hub import snapshot_download; \
snapshot_download('black-forest-labs/FLUX.2-klein-4B', revision='${FLUX_MODEL_REV}', \
  allow_patterns=['*.json','*.safetensors','*.txt','tokenizer*/*','text_encoder*/*','transformer/*','vae/*','scheduler/*','model_index.json']); \
print('FLUX.2-klein-4B base weights cached')"

# ─── Layer 4: NVFP4 transformer weights (~7 GB) ─────────────────────────
ARG NVFP4_REV=main
RUN python -c "\
from huggingface_hub import hf_hub_download; \
hf_hub_download('black-forest-labs/FLUX.2-klein-4b-nvfp4', 'flux-2-klein-4b-nvfp4.safetensors', revision='${NVFP4_REV}'); \
print('NVFP4 weights cached')"

# ─── Layer 5: server code ───────────────────────────────────────────────
# Changes most often; last layer → fast incremental rebuilds.
WORKDIR /app
COPY server.py pipeline.py config.py /app/

# Offline mode — refuse network lookups once we're baked. Prevents a transient
# DNS issue from triggering a re-download.
ENV HF_HUB_OFFLINE=1

ENV FLUX_HOST=0.0.0.0
ENV FLUX_PORT=8766
ENV FLUX_USE_NVFP4=1

EXPOSE 8766

# Exec form so SIGTERM reaches python directly (uvicorn handles shutdown).
CMD ["python", "-u", "/app/server.py"]
