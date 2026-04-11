FROM nvidia/cuda:12.4.1-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive

# System deps
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3.11 python3-pip python3.11-dev git \
    && rm -rf /var/lib/apt/lists/*

RUN python3 -m pip install --no-cache-dir --upgrade pip

WORKDIR /app

# Install PyTorch with CUDA 12.4
RUN pip install --no-cache-dir \
    torch>=2.2.0 \
    --index-url https://download.pytorch.org/whl/cu124

# Install diffusers from git (required for FLUX.2-klein support)
RUN pip install --no-cache-dir \
    git+https://github.com/huggingface/diffusers.git \
    transformers>=4.40.0 \
    accelerate>=0.28.0 \
    sentencepiece>=0.2.0

# Install server deps
RUN pip install --no-cache-dir \
    "fastapi>=0.108.0" "uvicorn[standard]>=0.25.0" "websockets>=12.0" "Pillow>=10.0.0"

# Pre-download model weights so they're baked into the image
RUN python3 -c " \
from diffusers import Flux2KleinPipeline; \
Flux2KleinPipeline.from_pretrained('black-forest-labs/FLUX.2-klein-4B') \
"

COPY . .

EXPOSE 8766

CMD ["python3", "server.py"]
