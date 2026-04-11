"""FLUX.2-klein img2img pipeline with reference and denoise modes."""

import logging
import threading
import time

import torch
from PIL import Image

import config

logger = logging.getLogger(__name__)


class FluxKleinPipeline:
    """Wraps FLUX.2-klein for img2img generation with two modes.

    Mode A (reference): Uses the pipeline's native image conditioning.
    The sketch is VAE-encoded and concatenated with generation latents
    via the pipeline's built-in ``image`` parameter.

    Mode B (denoise): Traditional img2img via latent noise injection.
    Encodes sketch to latent space, adds noise proportional to
    denoise_strength using the pipeline's scheduler, then denoises.
    """

    def __init__(self):
        self.pipe = None
        self._ready = False
        self._dtype = getattr(torch, config.DTYPE)
        # Serialize pipeline calls — PyTorch is not thread-safe and
        # asyncio.to_thread could overlap frames.
        self._lock = threading.Lock()

    @property
    def ready(self) -> bool:
        return self._ready

    def load(self) -> None:
        """Load FLUX.2-klein model and warm up."""
        logger.info("Loading model: %s (dtype=%s)", config.MODEL_ID, config.DTYPE)
        t0 = time.time()

        from diffusers import Flux2KleinPipeline

        self.pipe = Flux2KleinPipeline.from_pretrained(
            config.MODEL_ID,
            torch_dtype=self._dtype,
        )
        self.pipe.to("cuda")

        logger.info("Model loaded in %.1fs", time.time() - t0)

        # Warmup with a dummy txt2img generation
        logger.info("Warming up...")
        t1 = time.time()
        with self._lock:
            _ = self.pipe(
                prompt="warmup",
                height=config.DEFAULT_HEIGHT,
                width=config.DEFAULT_WIDTH,
                num_inference_steps=config.STEPS,
                guidance_scale=1.0,
                generator=torch.Generator(device="cuda").manual_seed(0),
            )
        logger.info("Warmup done (%.1fs)", time.time() - t1)

        self._ready = True
        logger.info("Pipeline ready. Total init: %.1fs", time.time() - t0)

    def generate_reference(
        self,
        image: Image.Image,
        prompt: str,
        steps: int = config.STEPS,
        guidance_scale: float = config.GUIDANCE_SCALE,
        seed: int | None = None,
    ) -> Image.Image:
        """Mode A: Native reference editing.

        The sketch is passed as a conditioning image via the pipeline's
        ``image`` parameter.  Internally the model VAE-encodes it,
        patchifies the latents, and concatenates them with generation
        latents so the transformer attends to both.
        """
        generator = self._make_generator(seed)

        with self._lock:
            result = self.pipe(
                prompt=prompt,
                image=image,
                height=config.DEFAULT_HEIGHT,
                width=config.DEFAULT_WIDTH,
                num_inference_steps=steps,
                guidance_scale=guidance_scale,
                generator=generator,
            )
        return result.images[0]

    def generate_denoise(
        self,
        image: Image.Image,
        prompt: str,
        denoise_strength: float = config.DENOISE_STRENGTH,
        steps: int = config.STEPS,
        seed: int | None = None,
    ) -> Image.Image:
        """Mode B: Traditional img2img via latent noise injection.

        Encodes the sketch into latent space using the pipeline's VAE,
        adds noise proportional to ``denoise_strength`` using the
        flow-matching schedule, and denoises from that starting point.

        NOTE: This mode accesses pipeline internals that may change across
        diffusers versions. If encoding fails, it falls back to reference mode.
        """
        generator = self._make_generator(seed)

        with self._lock:
            pipe = self.pipe

            try:
                return self._denoise_impl(pipe, image, prompt, denoise_strength, steps, generator)
            except Exception as e:
                logger.warning(
                    "Denoise mode failed (%s), falling back to reference mode", e,
                )
                # Fallback: use reference mode instead
                result = pipe(
                    prompt=prompt,
                    image=image,
                    height=config.DEFAULT_HEIGHT,
                    width=config.DEFAULT_WIDTH,
                    num_inference_steps=steps,
                    guidance_scale=config.GUIDANCE_SCALE,
                    generator=generator,
                )
                return result.images[0]

    @staticmethod
    def _denoise_impl(pipe, image, prompt, denoise_strength, steps, generator):
        """Internal denoise implementation — may raise if pipeline internals differ."""
        import numpy as np
        from torchvision import transforms

        image_resized = image.resize(
            (config.DEFAULT_WIDTH, config.DEFAULT_HEIGHT), Image.LANCZOS,
        )

        # Encode to tensor
        to_tensor = transforms.Compose([
            transforms.ToTensor(),
            transforms.Normalize([0.5], [0.5]),  # Scale to [-1, 1]
        ])
        image_tensor = to_tensor(image_resized).unsqueeze(0)
        image_tensor = image_tensor.to(device="cuda", dtype=pipe.dtype)

        # VAE encode
        with torch.no_grad():
            latent_dist = pipe.vae.encode(image_tensor)
            latents = latent_dist.latent_dist.sample(generator)

        # Normalize latents using VAE batch norm if available,
        # otherwise use scaling_factor
        if hasattr(pipe.vae, "bn") and pipe.vae.bn is not None:
            bn_mean = pipe.vae.bn.running_mean.view(1, -1, 1, 1).to(latents.device)
            bn_var = pipe.vae.bn.running_var.to(latents.device)
            bn_eps = getattr(pipe.vae.config, "batch_norm_eps", 1e-5)
            bn_std = torch.sqrt(bn_var + bn_eps).view(1, -1, 1, 1)
            latents = (latents - bn_mean) / bn_std
        elif hasattr(pipe.vae.config, "scaling_factor"):
            latents = latents * pipe.vae.config.scaling_factor

        # Patchify if the pipeline requires it
        if hasattr(pipe, "_pack_latents"):
            latents = pipe._pack_latents(
                latents,
                latents.shape[0],
                latents.shape[1],
                latents.shape[2],
                latents.shape[3],
            )

        # Set up scheduler and compute noise
        pipe.scheduler.set_timesteps(steps, device="cuda")
        timesteps = pipe.scheduler.timesteps

        # Skip early steps based on denoise_strength
        skip = int(round(len(timesteps) * (1.0 - denoise_strength)))
        timesteps = timesteps[skip:]

        if len(timesteps) == 0:
            return image_resized

        # Add noise at the first remaining timestep
        noise = torch.randn_like(latents, generator=generator)
        sigma = timesteps[0].float() / pipe.scheduler.config.num_train_timesteps
        noisy_latents = (1.0 - sigma) * latents + sigma * noise

        # Run pipeline from pre-noised latents
        result = pipe(
            prompt=prompt,
            height=config.DEFAULT_HEIGHT,
            width=config.DEFAULT_WIDTH,
            num_inference_steps=steps,
            latents=noisy_latents,
            guidance_scale=1.0,
            generator=generator,
        )
        return result.images[0]

    def _make_generator(self, seed: int | None) -> torch.Generator | None:
        if seed is not None:
            return torch.Generator(device="cuda").manual_seed(seed)
        return None

    def get_info(self) -> dict:
        """Return pipeline info for health endpoint."""
        gpu_name = torch.cuda.get_device_name(0) if torch.cuda.is_available() else "none"
        vram_free = 0.0
        if torch.cuda.is_available():
            vram_free = torch.cuda.mem_get_info()[0] / (1024**3)

        return {
            "model": config.MODEL_ID,
            "dtype": config.DTYPE,
            "default_mode": config.MODE,
            "default_steps": config.STEPS,
            "resolution": f"{config.DEFAULT_WIDTH}x{config.DEFAULT_HEIGHT}",
            "gpu": gpu_name,
            "vram_free_gb": round(vram_free, 2),
        }
