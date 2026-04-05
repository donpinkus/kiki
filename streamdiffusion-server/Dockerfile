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

# Install requirements (excluding torch/torchvision already installed)
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Install StreamDiffusion from source
RUN pip install --no-cache-dir \
    git+https://github.com/cumulo-autumn/StreamDiffusion.git@main#egg=streamdiffusion

# Pre-download models so they're baked into the image
RUN python3 -c " \
from diffusers import AutoPipelineForImage2Image; \
AutoPipelineForImage2Image.from_pretrained('Lykon/dreamshaper-8', torch_dtype='auto'); \
from huggingface_hub import hf_hub_download; \
hf_hub_download('latent-consistency/lcm-lora-sdv1-5', 'pytorch_lora_weights.safetensors') \
"

COPY . .

EXPOSE 8765

CMD ["python3", "server.py"]
