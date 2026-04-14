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
        self._quantization = "bf16"  # overwritten to "nvfp4" if that path succeeds
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

        # Optional: overwrite the transformer with BFL's NVFP4 weights for 2.7× speedup.
        # Must happen BEFORE .to("cuda") so the new weights land on device.
        if config.USE_NVFP4:
            self._try_load_nvfp4()

        self.pipe.to("cuda")

        logger.info("Model loaded in %.1fs (quantization=%s)", time.time() - t0, self._quantization)

        # One-off: wrap VAE + text-encoder + transformer forward passes with
        # cuda-synchronized timers so we can break down the 985ms pipe cost.
        self._instrument_for_benchmark()

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
            # No silent fallback — if denoise is broken, surface it. The prior
            # fallback caused a phantom "mode switch" effect: denoise consumed
            # RNG via pipe.vae.encode → .sample(generator), then fell back to
            # reference with an advanced generator, producing visibly different
            # output for the same seed. That looked like denoise "worked" when
            # it was actually reference-mode output with perturbed noise.
            return self._denoise_impl(self.pipe, image, prompt, denoise_strength, steps, generator)

    @staticmethod
    def _denoise_impl(pipe, image, prompt, denoise_strength, steps, generator):
        """True img2img denoise for FLUX.2 klein.

        Reuses the pipeline's own primitives (`_encode_vae_image`, `encode_prompt`,
        `prepare_latents`, scheduler, transformer, VAE decode) but orchestrates
        them in an inline loop so we can slice the scheduler's timesteps and
        inject noise at the chosen sigma. Does NOT pass `image=` to the
        transformer — no reference tokens, so transformer runs at txt2img speed
        (~117ms/step on 5090+NVFP4) vs reference mode's ~217ms/step.

        Shape progression (for 768×768, 4 steps, denoise_strength=0.6):
          sketch PIL → tensor (1,3,768,768)
          → _encode_vae_image → (1,128,48,48) BN-normalized
          → _pack_latents → (1,2304,128) packed
          → noise-injected at sigma of first sliced timestep
          → loop over 2-3 timesteps running transformer + scheduler.step
          → _unpack_latents_with_ids → (1,128,48,48)
          → reverse BN → (1,128,48,48) raw-latent space
          → _unpatchify_latents → (1,32,96,96)
          → vae.decode → (1,3,768,768)
          → image_processor.postprocess → PIL
        """
        # Wrap everything in no_grad. The public pipe.__call__ has this as
        # a decorator — without it, transformer activations are retained
        # for autograd and pin ~30GB on the 5090, OOM'ing after step 1.
        with torch.no_grad():
            return FluxKleinPipeline._denoise_inner(
                pipe, image, prompt, denoise_strength, steps, generator,
                config.DEFAULT_HEIGHT, config.DEFAULT_WIDTH, pipe._execution_device,
            )

    @staticmethod
    def _denoise_inner(pipe, image, prompt, denoise_strength, steps, generator, H, W, device):
        from diffusers.pipelines.flux2.pipeline_flux2_klein import (
            compute_empirical_mu,
            retrieve_timesteps,
        )

        # 1. Preprocess sketch into tensor (B, 3, H, W).
        image_tensor = pipe.image_processor.preprocess(
            image, height=H, width=W, resize_mode="crop",
        ).to(device=device, dtype=pipe.vae.dtype)
        logger.debug("denoise: image_tensor shape=%s", tuple(image_tensor.shape))

        # 2. VAE-encode into normalized latent space. Returns (1, 128, H/16, W/16).
        image_latents = pipe._encode_vae_image(image=image_tensor, generator=generator)
        logger.debug("denoise: image_latents shape=%s", tuple(image_latents.shape))

        # 3. Prompt embeddings.
        prompt_embeds, text_ids = pipe.encode_prompt(
            prompt=prompt,
            device=device,
            num_images_per_prompt=1,
            max_sequence_length=512,
        )

        # 4. Use the pipeline's own prepare_latents to pack our image_latents
        # and get matching latent_ids. num_latents_channels = transformer.in_channels // 4.
        num_latents_channels = pipe.transformer.config.in_channels // 4
        packed_latents, latent_ids = pipe.prepare_latents(
            batch_size=1,
            num_latents_channels=num_latents_channels,
            height=H,
            width=W,
            dtype=prompt_embeds.dtype,
            device=device,
            generator=generator,
            latents=image_latents,  # reuse our sketch-derived latents instead of randn
        )
        logger.debug(
            "denoise: packed_latents shape=%s, latent_ids shape=%s",
            tuple(packed_latents.shape), tuple(latent_ids.shape),
        )

        # 5. Ask the scheduler for the full schedule. Flow-matching schedulers
        # use `mu` derived from image sequence length.
        image_seq_len = packed_latents.shape[1]
        mu = compute_empirical_mu(image_seq_len=image_seq_len, num_steps=steps)
        timesteps, num_inference_steps = retrieve_timesteps(
            pipe.scheduler, steps, device, sigmas=None, mu=mu,
        )

        # 6. Slice to the last `denoise_strength` fraction of steps.
        start_idx = int(round(num_inference_steps * (1.0 - denoise_strength)))
        timesteps = timesteps[start_idx:]
        if len(timesteps) == 0:
            # denoise_strength == 0 → just VAE-roundtrip the sketch through decode.
            timesteps = timesteps[-1:]

        # 7. Inject noise at the starting sigma. Flow-matching scale_noise:
        # noisy = (1 - sigma)*x0 + sigma*noise
        noise = torch.randn(
            packed_latents.shape,
            generator=generator,
            device=device,
            dtype=packed_latents.dtype,
        )
        # scale_noise wants scalar-index timesteps; pass a length-1 tensor.
        latents = pipe.scheduler.scale_noise(
            packed_latents, timesteps[:1], noise,
        )
        logger.debug("denoise: noisy latents ready, sliced steps=%d", len(timesteps))

        # 8. Inline denoising loop. Mirrors pipeline_flux2_klein.__call__'s inner loop
        # but WITHOUT the image_latents concat path — this is img2img denoise, not
        # reference. `guidance=None` because klein is step-wise distilled.
        pipe.scheduler.set_begin_index(0)
        for t in timesteps:
            timestep = t.expand(latents.shape[0]).to(latents.dtype)
            latent_model_input = latents.to(pipe.transformer.dtype)

            with pipe.transformer.cache_context("cond"):
                noise_pred = pipe.transformer(
                    hidden_states=latent_model_input,
                    timestep=timestep / 1000,
                    guidance=None,
                    encoder_hidden_states=prompt_embeds,
                    txt_ids=text_ids,
                    img_ids=latent_ids,
                    joint_attention_kwargs=None,
                    return_dict=False,
                )[0]
            # Klein is distilled → no CFG. noise_pred is already the right size.

            latents_dtype = latents.dtype
            latents = pipe.scheduler.step(noise_pred, t, latents, return_dict=False)[0]
            if latents.dtype != latents_dtype:
                latents = latents.to(latents_dtype)

        # 9. Unpack: (1, H_lat*W_lat, 128) → (1, 128, H_lat/2, W_lat/2).
        latent_h = 2 * (H // (pipe.vae_scale_factor * 2))
        latent_w = 2 * (W // (pipe.vae_scale_factor * 2))
        latents = pipe._unpack_latents_with_ids(
            latents, latent_ids, latent_h // 2, latent_w // 2,
        )

        # 10. Reverse the VAE batch-norm that _encode_vae_image applied.
        bn_mean = pipe.vae.bn.running_mean.view(1, -1, 1, 1).to(latents.device, latents.dtype)
        bn_std = torch.sqrt(
            pipe.vae.bn.running_var.view(1, -1, 1, 1) + pipe.vae.config.batch_norm_eps,
        ).to(latents.device, latents.dtype)
        latents = latents * bn_std + bn_mean

        # 11. Reverse the 2×2 patchify → raw VAE latent shape (1, 32, H/8, W/8).
        latents = pipe._unpatchify_latents(latents)

        # 12. Decode to pixels and return PIL.
        image_out = pipe.vae.decode(latents, return_dict=False)[0]
        pil_images = pipe.image_processor.postprocess(image_out, output_type="pil")
        return pil_images[0] if isinstance(pil_images, list) else pil_images

    def _make_generator(self, seed: int | None) -> torch.Generator | None:
        if seed is not None:
            return torch.Generator(device="cuda").manual_seed(seed)
        return None

    def _instrument_for_benchmark(self) -> None:
        """Wrap pipeline sub-components with cuda-synced timing logs.

        Logs one line per invocation: `component=X duration_ms=Y`.
        Transformer fires once per diffusion step; VAE encode/decode and
        text-encoder fire once per frame. Drop this method once we're done
        benchmarking — it's not free, but adds maybe 1ms per frame from syncs.
        """

        def wrap(name: str, fn):
            def wrapped(*args, **kwargs):
                torch.cuda.synchronize()
                t = time.perf_counter()
                result = fn(*args, **kwargs)
                torch.cuda.synchronize()
                dur_ms = (time.perf_counter() - t) * 1000
                logger.info("pipe_component name=%s duration_ms=%.1f", name, dur_ms)
                return result
            return wrapped

        pipe = self.pipe
        # VAE encode/decode: always present
        if hasattr(pipe, "vae") and pipe.vae is not None:
            pipe.vae.encode = wrap("vae_encode", pipe.vae.encode)
            pipe.vae.decode = wrap("vae_decode", pipe.vae.decode)

        # Text encoder(s): FLUX.2 uses Qwen3-8B. Diffusers exposes it at
        # pipe.text_encoder and/or via pipe.encode_prompt().
        if hasattr(pipe, "encode_prompt"):
            pipe.encode_prompt = wrap("encode_prompt", pipe.encode_prompt)

        # Transformer fires per step; lets us see diffusion-step wall-clock.
        if hasattr(pipe, "transformer") and pipe.transformer is not None:
            # Wrap __call__ on the module by wrapping .forward.
            orig_forward = pipe.transformer.forward
            pipe.transformer.forward = wrap("transformer_step", orig_forward)

        logger.info("Instrumentation attached (vae.encode/decode, encode_prompt, transformer.forward)")

    def _try_load_nvfp4(self) -> None:
        """Overwrite transformer weights with BFL's NVFP4 checkpoint.

        NVFP4 requires Blackwell (SM 10.0+) silicon. On older GPUs or if the
        weights file shape-mismatches the current diffusers version, we log a
        warning and leave the BF16 weights in place so the pipeline still runs.
        """
        if not torch.cuda.is_available():
            logger.warning("NVFP4 requested but CUDA not available; staying on BF16")
            return

        major, _ = torch.cuda.get_device_capability(0)
        if major < 10:
            logger.warning(
                "NVFP4 requires Blackwell (SM 10+); detected SM %d.x. Staying on BF16.",
                major,
            )
            return

        try:
            from huggingface_hub import hf_hub_download
            from safetensors.torch import load_file

            logger.info(
                "Loading NVFP4 transformer weights from %s (%s)...",
                config.NVFP4_REPO, config.NVFP4_FILENAME,
            )
            t0 = time.time()
            nvfp4_path = hf_hub_download(
                repo_id=config.NVFP4_REPO,
                filename=config.NVFP4_FILENAME,
            )
            state_dict = load_file(nvfp4_path)
            missing, unexpected = self.pipe.transformer.load_state_dict(
                state_dict, strict=False,
            )
            logger.info(
                "NVFP4 weights loaded in %.1fs (missing=%d, unexpected=%d)",
                time.time() - t0, len(missing), len(unexpected),
            )
            self._quantization = "nvfp4"
        except Exception as e:  # noqa: BLE001 — want all-exception fallback
            logger.warning(
                "NVFP4 load failed (%s: %s); falling back to BF16",
                type(e).__name__, e,
            )

    def get_info(self) -> dict:
        """Return pipeline info for health endpoint."""
        gpu_name = torch.cuda.get_device_name(0) if torch.cuda.is_available() else "none"
        vram_free = 0.0
        if torch.cuda.is_available():
            vram_free = torch.cuda.mem_get_info()[0] / (1024**3)

        return {
            "model": config.MODEL_ID,
            "dtype": config.DTYPE,
            "quantization": self._quantization,
            "default_mode": config.MODE,
            "default_steps": config.STEPS,
            "resolution": f"{config.DEFAULT_WIDTH}x{config.DEFAULT_HEIGHT}",
            "gpu": gpu_name,
            "vram_free_gb": round(vram_free, 2),
        }
