"""H100 benchmark for the LTX-2.5 serving path — runs the real serving class
(``video.pipeline.Ltx25VideoPipeline``) at several output sizes and writes
MP4s + a timing/VRAM summary so quality and latency can be compared offline.

The pipeline kind is a LOAD-time choice (env ``LTX_PIPELINE=distilled|dfr``),
so run this once per pipeline. ``LTX_WIDTH``/``LTX_HEIGHT`` set the warmup
shape; pass ``--sizes`` for the shapes to measure after warmup.

Usage (on the instance, venv active, from $FS/kiki/app):
    HF_HOME=$FS/kiki/huggingface HF_HUB_OFFLINE=1 LTX_PIPELINE=distilled LTX_WIDTH=512 LTX_HEIGHT=512 \
    PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True \
    python3 -m dev.bench_ltx25 --image /tmp/start.jpg [--end-image /tmp/end.jpg] \
        --prompt "..." --sizes 512,768,1024 --frames 97 --out /tmp/bench
"""
from __future__ import annotations

import argparse
import json
import logging
import os
import sys
import time

from PIL import Image


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--image", required=True)
    parser.add_argument("--end-image", default=None)
    parser.add_argument("--prompt", default="gentle cinematic motion, the scene subtly comes alive")
    parser.add_argument("--sizes", default="512,768,1024")
    parser.add_argument("--frames", type=int, default=97)
    parser.add_argument("--repeat", type=int, default=1)
    parser.add_argument("--seed", type=int, default=7)
    parser.add_argument("--out", default="/tmp/bench")
    parser.add_argument("--label", default=None, help="tag written into the summary rows")
    parser.add_argument("--frames-list", default=None, help="csv of frame counts (overrides --frames)")
    args = parser.parse_args()

    os.makedirs(args.out, exist_ok=True)
    # Full log (incl. ltx_pipelines' per-block 'Building …' lines) to a file
    # for stage attribution; the console keeps only our [bench] rows.
    logging.basicConfig(
        level=logging.INFO, format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
        handlers=[logging.FileHandler(os.path.join(args.out, "full.log"))],
    )

    import torch

    from shared import config
    from video.pipeline import Keyframe, Ltx25VideoPipeline
    from video.server import _encode_mp4

    pipeline_name = config.LTX_PIPELINE
    t0 = time.time()
    pipe = Ltx25VideoPipeline()
    pipe.load()
    load_s = time.time() - t0
    info = pipe.get_info()
    print(f"[bench] loaded {pipeline_name} label={args.label} in {load_s:.1f}s; phase_timings={info['phase_timings_ms']} "
          f"resident_vram={info['resident_vram_gb']} GiB attention={info.get('attention')} compile={info.get('torch_compile')}", flush=True)

    start = Image.open(args.image).convert("RGB")
    keyframes = [Keyframe(image=start, position=0.0, strength=1.0)]
    if args.end_image:
        keyframes.append(Keyframe(image=Image.open(args.end_image).convert("RGB"), position=1.0, strength=1.0))

    summary: list[dict] = []
    frames_list = [int(x) for x in (args.frames_list or str(args.frames)).split(",") if x.strip()]
    for size in [int(s) for s in args.sizes.split(",") if s.strip()]:
      for num_frames in frames_list:
        args.frames = num_frames
        for rep in range(args.repeat):
              torch.cuda.reset_peak_memory_stats()
              t1 = time.time()
              try:
                  result = pipe.generate(
                      None, args.prompt, args.seed + rep, lambda: False,
                      keyframes=keyframes, width=size, height=size, num_frames=args.frames,
                  )
              except Exception as e:  # noqa: BLE001
                  print(f"[bench] {pipeline_name} {size}x{size}x{args.frames} FAILED: {e!r}", flush=True)
                  summary.append({"pipeline": pipeline_name, "size": size, "frames": args.frames,
                                  "error": repr(e)[:400]})
                  torch.cuda.empty_cache()
                  continue
              wall_s = time.time() - t1
              peak_gb = torch.cuda.max_memory_allocated() / (1024**3)
              frames = result.frames or []
              mp4 = _encode_mp4(frames, config.LTX_FPS, result.audio)
              name = f"{pipeline_name}-{size}-{args.frames}f-r{rep}"
              with open(os.path.join(args.out, name + ".mp4"), "wb") as f:
                  f.write(mp4)
              if frames:
                  frames[len(frames) // 2].save(os.path.join(args.out, name + "-mid.jpg"), quality=90)
                  frames[-1].save(os.path.join(args.out, name + "-last.jpg"), quality=90)
              row = {
                  "label": args.label, "pipeline": pipeline_name, "size": size, "frames": args.frames, "rep": rep,
                  "wall_s": round(wall_s, 1), "pipe_total_ms": result.pipe_total_ms,
                  "peak_vram_gb": round(peak_gb, 2), "frames_out": len(frames),
                  "audio": result.audio is not None, "mp4_bytes": len(mp4),
                  "timings": {k: v for k, v in pipe._inference_timings.items()},
              }
              summary.append(row)
              print(f"[bench] {json.dumps(row)}", flush=True)

    with open(os.path.join(args.out, f"summary-{pipeline_name}.json"), "w") as f:
        json.dump({"load_s": round(load_s, 1), "info": info, "runs": summary}, f, indent=2, default=str)
    print(f"[bench] done → {args.out}", flush=True)
    sys.exit(0)


if __name__ == "__main__":
    main()
