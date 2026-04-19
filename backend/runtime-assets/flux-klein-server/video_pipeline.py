"""LTXV 2B 0.9.8 distilled image-to-video pipeline.

Runs alongside the FLUX img2img pipeline on the same GPU. When the user stops
drawing (input buffer goes idle), the server feeds the last generated still
into this pipeline as a keyframe and streams back frames + a looping MP4.

Uses LTXConditionPipeline (0.9.5+ API) with the 2B 0.9.8 distilled
transformer loaded from a single-file checkpoint. Weights are stored in FP8
(float8_e4m3fn) via enable_layerwise_casting for lower VRAM and faster
inference on Blackwell tensor cores; compute stays in BF16.

Kept deliberately minimal — resolution, frame count, and step count are
tuned for speed (SLA: <5s time-to-first-playback), not quality.
"""
from __future__ import annotations

import io
import logging
import subprocess
import tempfile
import threading
import time
from pathlib import Path

import torch
from PIL import Image

import config

logger = logging.getLogger(__name__)


class VideoCancelled(Exception):
    """Raised from the per-step callback to abort a running LTXV generation
    when the user resumes drawing. Caller should suppress this and treat it
    as a normal cancellation, not an error."""


class LtxvVideoPipeline:
    """Wraps LTX-Video 2B 0.9.8 distilled for image-to-video generation.

    The pipeline is loaded once at pod startup and reused across all client
    connections. Concurrent access is serialized via `gpu_lock` (passed in
    by the server so FLUX and LTXV can't run at the same time on the same
    CUDA stream).
    """

    def __init__(self, gpu_lock: threading.Lock):
        self.pipe = None
        self._ready = False
        self._dtype = getattr(torch, config.LTXV_DTYPE)
        self._gpu_lock = gpu_lock

    @property
    def ready(self) -> bool:
        return self._ready

    def load(self) -> None:
        if not config.ENABLE_VIDEO:
            logger.info("Video generation disabled (KIKI_ENABLE_VIDEO=0); skipping LTXV load")
            return

        logger.info(
            "Loading LTXV 2B 0.9.8 distilled (base=%s, transformer=%s/%s)",
            config.LTXV_BASE_REPO, config.LTXV_TRANSFORMER_REPO,
            config.LTXV_TRANSFORMER_FILE,
        )
        t0 = time.time()

        try:
            from diffusers import AutoModel, LTXConditionPipeline

            # Load the 2B transformer from the pre-quantized FP8 checkpoint.
            # from_single_file upcasts to BF16 on load; we then apply
            # layerwise_casting to store FP8 / compute BF16 for inference.
            logger.info("Loading transformer from single file...")
            transformer = AutoModel.from_single_file(
                f"https://huggingface.co/{config.LTXV_TRANSFORMER_REPO}/blob/main/{config.LTXV_TRANSFORMER_FILE}",
                config=config.LTXV_BASE_REPO,
                subfolder="transformer",
                torch_dtype=self._dtype,
            )

            logger.info("Applying FP8 layerwise casting...")
            transformer.enable_layerwise_casting(
                storage_dtype=torch.float8_e4m3fn,
                compute_dtype=torch.bfloat16,
            )

            # Assemble the full pipeline from the 0.9.5 repo (VAE, text
            # encoder, scheduler) with our transformer swapped in.
            logger.info("Assembling pipeline from %s...", config.LTXV_BASE_REPO)
            self.pipe = LTXConditionPipeline.from_pretrained(
                config.LTXV_BASE_REPO,
                transformer=transformer,
                torch_dtype=self._dtype,
            ).to("cuda")
            self.pipe.vae.enable_tiling()

            # Warmup so the first user-facing call doesn't pay CUDA graph /
            # kernel compilation cost.
            logger.info("Warming up LTXV...")
            t1 = time.time()
            warmup_image = Image.new("RGB", (config.LTXV_WIDTH, config.LTXV_HEIGHT), "gray")
            with self._gpu_lock:
                self._run_generation(warmup_image, "warmup", None, 0)
            logger.info("LTXV warmup done (%.1fs)", time.time() - t1)
            self._ready = True
            logger.info("LTXV ready. Total init: %.1fs", time.time() - t0)
        except Exception as e:  # noqa: BLE001 — want fail-soft so FLUX still serves
            logger.error("LTXV load failed (%s: %s); video generation disabled", type(e).__name__, e)
            self.pipe = None
            self._ready = False

    def _run_generation(
        self,
        image: Image.Image,
        prompt: str,
        cancel_event: threading.Event | None,
        seed: int | None,
    ) -> list[Image.Image]:
        """Inner generation call — assumes gpu_lock is held."""
        from diffusers.pipelines.ltx.pipeline_ltx_condition import LTXVideoCondition
        from diffusers.utils import export_to_video, load_video

        # LTXConditionPipeline expects video-codec-compressed conditioning.
        # Export the single image as a 1-frame video, then load it back.
        keyframe = image.convert("RGB").resize(
            (config.LTXV_WIDTH, config.LTXV_HEIGHT), Image.LANCZOS
        )
        with tempfile.NamedTemporaryFile(suffix=".mp4", delete=True) as tmp:
            export_to_video([keyframe], tmp.name, fps=config.LTXV_FPS)
            video_cond = load_video(tmp.name)
        condition = LTXVideoCondition(video=video_cond, frame_index=0)

        # Per-step cancel check.
        def step_cancel(pipe, step_index, timestep, callback_kwargs):
            if cancel_event is not None and cancel_event.is_set():
                raise VideoCancelled()
            return callback_kwargs

        generator = (
            torch.Generator(device="cuda").manual_seed(seed) if seed is not None else None
        )

        result = self.pipe(
            conditions=[condition],
            prompt=prompt or "",
            negative_prompt="worst quality, inconsistent motion, blurry, jittery, distorted",
            width=config.LTXV_WIDTH,
            height=config.LTXV_HEIGHT,
            num_frames=config.LTXV_NUM_FRAMES,
            timesteps=config.LTXV_TIMESTEPS,
            guidance_scale=config.LTXV_GUIDANCE,
            decode_timestep=0.05,
            decode_noise_scale=0.025,
            generator=generator,
            callback_on_step_end=step_cancel,
            output_type="pil",
        )

        frames = result.frames[0] if hasattr(result, "frames") else result.videos[0]
        return list(frames)

    def generate(
        self,
        image: Image.Image,
        prompt: str,
        cancel_event: threading.Event,
        seed: int | None = None,
    ) -> list[Image.Image]:
        """Generate an image-to-video animation.

        Returns the list of decoded frames (PIL images). If `cancel_event`
        is set between steps, raises `VideoCancelled` — the caller should
        catch this and treat it as a normal abort.
        """
        if not self._ready or self.pipe is None:
            raise RuntimeError("LTXV pipeline not ready")

        with self._gpu_lock:
            if cancel_event.is_set():
                raise VideoCancelled()
            return self._run_generation(image, prompt, cancel_event, seed)

    def get_info(self) -> dict:
        return {
            "video_enabled": config.ENABLE_VIDEO,
            "video_ready": self._ready,
            "video_model": "ltxv-2b-0.9.8-distilled-fp8" if self._ready else None,
            "video_resolution": f"{config.LTXV_WIDTH}x{config.LTXV_HEIGHT}",
            "video_num_frames": config.LTXV_NUM_FRAMES,
        }


def frames_to_jpeg(frame: Image.Image, quality: int = 80) -> bytes:
    buf = io.BytesIO()
    frame.save(buf, format="JPEG", quality=quality)
    return buf.getvalue()


def encode_mp4(frames: list[Image.Image], fps: int, crf: int) -> bytes:
    """Encode a list of PIL frames into an H.264 MP4 blob via ffmpeg.

    Writes frames as PNGs to a tempdir and invokes ffmpeg once. ~200–500ms
    overhead for a short clip — acceptable within the <5s SLA.
    """
    if not frames:
        raise ValueError("encode_mp4: no frames")

    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        for i, f in enumerate(frames):
            f.save(tmp_path / f"frame_{i:05d}.png")
        out_path = tmp_path / "out.mp4"

        # yuv420p + even dimensions needed for AVPlayer/Safari compatibility.
        subprocess.run(
            [
                "ffmpeg",
                "-loglevel", "error",
                "-y",
                "-framerate", str(fps),
                "-i", str(tmp_path / "frame_%05d.png"),
                "-c:v", "libx264",
                "-pix_fmt", "yuv420p",
                "-crf", str(crf),
                "-movflags", "+faststart",
                str(out_path),
            ],
            check=True,
        )
        return out_path.read_bytes()
