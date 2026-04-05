"""StreamDiffusion pipeline wrapper for real-time img2img generation."""

import logging
import time

import torch
from diffusers import StableDiffusionImg2ImgPipeline
from streamdiffusion import StreamDiffusion
from streamdiffusion.image_utils import postprocess_image

import config

logger = logging.getLogger(__name__)


class StreamPipeline:
    """Wraps StreamDiffusion for real-time img2img with LCM-LoRA."""

    def __init__(self):
        self.stream: StreamDiffusion | None = None
        self.current_prompt: str = ""
        self.current_strength: float = config.DEFAULT_STRENGTH
        self._ready = False

    @property
    def ready(self) -> bool:
        return self._ready

    def load(self) -> None:
        """Load model and initialize the StreamDiffusion pipeline."""
        logger.info("Loading base model: %s", config.BASE_MODEL)
        t0 = time.time()

        pipe = StableDiffusionImg2ImgPipeline.from_pretrained(
            config.BASE_MODEL,
            torch_dtype=torch.float16,
            safety_checker=None,
        ).to("cuda")

        logger.info("Model loaded in %.1fs. Initializing StreamDiffusion...", time.time() - t0)

        self.stream = StreamDiffusion(
            pipe,
            t_index_list=config.T_INDEX_LIST,
            torch_dtype=torch.float16,
            cfg_type="none",  # LCM doesn't need CFG
        )

        # Load LCM-LoRA for fast inference
        logger.info("Loading LCM-LoRA: %s", config.LCM_LORA)
        self.stream.load_lcm_lora(config.LCM_LORA)
        self.stream.fuse_lora()

        # Use accelerated VAE
        self.stream.vae = torch.compile(self.stream.vae, mode="reduce-overhead")

        if config.ENABLE_SIMILARITY_FILTER:
            self.stream.enable_similar_image_filter(
                threshold=config.SIMILARITY_THRESHOLD,
                max_skip_frame=5,
            )

        # Warm up with default prompt
        self._prepare_prompt(config.DEFAULT_PROMPT, config.DEFAULT_STRENGTH)

        # Warmup pass to compile/optimize
        logger.info("Running warmup pass...")
        warmup_image = torch.zeros(1, 3, config.DEFAULT_HEIGHT, config.DEFAULT_WIDTH).cuda().half()
        for _ in range(config.NUM_STEPS + 2):
            self.stream(warmup_image)

        self._ready = True
        logger.info("Pipeline ready. Total init: %.1fs", time.time() - t0)

    def update_config(self, prompt: str | None, strength: float | None) -> None:
        """Update prompt and/or strength if changed."""
        new_prompt = prompt if prompt is not None else self.current_prompt
        new_strength = strength if strength is not None else self.current_strength

        if new_prompt != self.current_prompt or new_strength != self.current_strength:
            self._prepare_prompt(new_prompt, new_strength)

    def process_frame(self, image_tensor: torch.Tensor) -> torch.Tensor | None:
        """Process a single frame through StreamDiffusion.

        Args:
            image_tensor: Input image tensor [C, H, W] in range [0, 1], float16, on CUDA.

        Returns:
            Output image tensor [C, H, W] or None if frame was skipped by similarity filter.
        """
        if not self._ready or self.stream is None:
            return None

        output = self.stream(image_tensor)
        return output

    def _prepare_prompt(self, prompt: str, strength: float) -> None:
        """Re-encode prompt and set denoising strength."""
        if self.stream is None:
            return

        self.current_prompt = prompt
        self.current_strength = strength

        # delta controls how much of the original image to preserve
        # Lower delta = more of original (less generation), higher = more generation
        self.stream.prepare(
            prompt=prompt,
            guidance_scale=config.GUIDANCE_SCALE,
            delta=strength,
        )
        logger.info("Prompt updated: '%s' (strength=%.2f)", prompt[:50], strength)

    def get_info(self) -> dict:
        """Return pipeline info for health endpoint."""
        gpu_name = torch.cuda.get_device_name(0) if torch.cuda.is_available() else "none"
        vram_free = 0.0
        if torch.cuda.is_available():
            vram_free = (torch.cuda.mem_get_info()[0]) / (1024**3)

        return {
            "model": config.BASE_MODEL,
            "lcm_lora": config.LCM_LORA,
            "steps": config.NUM_STEPS,
            "acceleration": config.ACCELERATION,
            "gpu": gpu_name,
            "vram_free_gb": round(vram_free, 2),
            "similarity_filter": config.ENABLE_SIMILARITY_FILTER,
        }
