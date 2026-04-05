FROM nvidia/cuda:12.1.0-runtime-ubuntu22.04

# Avoid interactive prompts
ENV DEBIAN_FRONTEND=noninteractive

# System deps
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3.10 python3-pip python3.10-dev git \
    && rm -rf /var/lib/apt/lists/*

# Upgrade pip
RUN python3 -m pip install --no-cache-dir --upgrade pip

WORKDIR /app

# Install PyTorch with CUDA 12.1
RUN pip install --no-cache-dir \
    torch==2.1.2+cu121 \
    torchvision==0.16.2+cu121 \
    --index-url https://download.pytorch.org/whl/cu121

# Install StreamDiffusion first (pins diffusers==0.24.0)
RUN pip install --no-cache-dir \
    git+https://github.com/cumulo-autumn/StreamDiffusion.git@main#egg=streamdiffusion

# Install server-only deps
RUN pip install --no-cache-dir \
    "fastapi>=0.108.0" "uvicorn[standard]>=0.25.0" "websockets>=12.0" "Pillow>=10.0.0"

# Pre-download models so they're baked into the image
RUN python3 -c " \
from diffusers import StableDiffusionImg2ImgPipeline; \
StableDiffusionImg2ImgPipeline.from_pretrained('Lykon/dreamshaper-8'); \
from huggingface_hub import hf_hub_download; \
hf_hub_download('latent-consistency/lcm-lora-sdv1-5', 'pytorch_lora_weights.safetensors') \
"

COPY . .

EXPOSE 8765

CMD ["python3", "server.py"]
