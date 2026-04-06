"""StreamDiffusion pipeline wrapper for real-time img2img generation."""

import logging
import time

import torch
from diffusers import StableDiffusionImg2ImgPipeline
from streamdiffusion import StreamDiffusion
import config

logger = logging.getLogger(__name__)


class StreamPipeline:
    """Wraps StreamDiffusion for real-time img2img with LCM-LoRA."""

    def __init__(self):
        self._pipe = None  # Base diffusers pipeline (reused across reinits)
        self.stream: StreamDiffusion | None = None
        self.current_prompt: str = ""
        self.current_t_index_list: list[int] = config.T_INDEX_LIST
        self._ready = False

    @property
    def ready(self) -> bool:
        return self._ready

    def load(self) -> None:
        """Load model and initialize the StreamDiffusion pipeline."""
        logger.info("Loading base model: %s", config.BASE_MODEL)
        t0 = time.time()

        self._pipe = StableDiffusionImg2ImgPipeline.from_pretrained(
            config.BASE_MODEL,
            torch_dtype=torch.float16,
            safety_checker=None,
        ).to("cuda")

        logger.info("Model loaded in %.1fs.", time.time() - t0)
        self._init_stream(config.T_INDEX_LIST)
        self._ready = True
        logger.info("Pipeline ready. Total init: %.1fs", time.time() - t0)

    def reinitialize(self, t_index_list: list[int]) -> None:
        """Reinitialize StreamDiffusion with new t_index_list.

        Reuses the loaded model weights — only the StreamDiffusion wrapper,
        LoRA, and noise schedule are re-created. Takes ~1-2s.
        """
        if t_index_list == self.current_t_index_list:
            return

        logger.info("Reinitializing with t_index_list=%s", t_index_list)
        self._ready = False
        self._init_stream(t_index_list)
        self._ready = True
        logger.info("Reinit complete. t_index_list=%s", t_index_list)

    def update_config(self, prompt: str | None) -> None:
        """Update prompt if changed."""
        new_prompt = prompt if prompt is not None else self.current_prompt
        if new_prompt != self.current_prompt:
            self._prepare_prompt(new_prompt)

    def process_frame(self, image_tensor: torch.Tensor) -> torch.Tensor | None:
        """Process a single frame. Returns output tensor or None if skipped."""
        if not self._ready or self.stream is None:
            return None
        return self.stream(image_tensor)

    def _init_stream(self, t_index_list: list[int]) -> None:
        """Create StreamDiffusion instance, load LoRA, prepare, warmup."""
        t0 = time.time()
        self.current_t_index_list = t_index_list

        self.stream = StreamDiffusion(
            self._pipe,
            t_index_list=t_index_list,
            torch_dtype=torch.float16,
            cfg_type="none",
        )

        self.stream.load_lcm_lora(config.LCM_LORA)
        self.stream.fuse_lora()
        self.stream.vae = torch.compile(self.stream.vae, mode="reduce-overhead")

        if config.ENABLE_SIMILARITY_FILTER:
            self.stream.enable_similar_image_filter(
                threshold=config.SIMILARITY_THRESHOLD,
                max_skip_frame=5,
            )

        self._prepare_prompt(self.current_prompt)

        # Warmup pass
        logger.info("Warmup (%d steps)...", len(t_index_list))
        warmup_image = torch.zeros(1, 3, config.DEFAULT_HEIGHT, config.DEFAULT_WIDTH).cuda().half()
        for _ in range(len(t_index_list) + 2):
            self.stream(warmup_image)
        logger.info("Warmup done (%.1fs)", time.time() - t0)

    def _prepare_prompt(self, prompt: str) -> None:
        """Re-encode prompt."""
        if self.stream is None:
            return
        self.current_prompt = prompt
        self.stream.prepare(
            prompt=prompt,
            guidance_scale=config.GUIDANCE_SCALE,
        )
        logger.info("Prompt: '%s'", prompt[:50])

    def get_info(self) -> dict:
        """Return pipeline info for health endpoint."""
        gpu_name = torch.cuda.get_device_name(0) if torch.cuda.is_available() else "none"
        vram_free = 0.0
        if torch.cuda.is_available():
            vram_free = (torch.cuda.mem_get_info()[0]) / (1024**3)

        return {
            "model": config.BASE_MODEL,
            "lcm_lora": config.LCM_LORA,
            "steps": len(self.current_t_index_list),
            "t_index_list": self.current_t_index_list,
            "acceleration": config.ACCELERATION,
            "gpu": gpu_name,
            "vram_free_gb": round(vram_free, 2),
            "similarity_filter": config.ENABLE_SIMILARITY_FILTER,
        }
