"""Protocol + perf probe for fal's HOSTED realtime model `fal-ai/flux-2/klein/realtime`.

This drives fal's HOSTED marketplace protocol (an earlier bench_stream.py spoke
our serverless app's custom protocol — config text + frame_meta + binary — and
was removed with that spike). The hosted marketplace model speaks
fal's realtime protocol — msgpack messages over `wss://fal.run/<model>/realtime`,
JWT minted server-side from FAL_KEY by the official fal_client. We drive it through
fal_client.realtime_async so the URL/auth/msgpack framing are handled canonically.

Answers the open questions from the migration plan:
  Q1 klein compute ms @ N steps  -> per-frame latency p50/p90/p99
  Q3 does fal drop-to-latest?     -> frames sent vs frames returned at 2 FPS
  Q4 WS idle survival             -> --idle-hold probe
  Q5 auth/url/protocol            -> if it connects + returns frames, confirmed
  cold start                      -> connect -> first frame wall time
  output framing                  -> prints the keys of the first message

Usage (FAL_KEY must be in env):
    set -a; . ../backend/.env.local; set +a
    .venv/bin/python scripts/bench_hosted_realtime.py \
        --prompt "a watercolor fox" --duration 30 --fps 2 --idle-hold 60
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import io
import os
import statistics
import time

import fal_client
from PIL import Image, ImageDraw


def _synthetic_sketch(size: int) -> Image.Image:
    """A simple black-line 'user sketch' on white — stand-in for the iPad canvas."""
    img = Image.new("RGB", (size, size), "white")
    d = ImageDraw.Draw(img)
    s = size
    # a little house
    d.rectangle([s * 0.30, s * 0.45, s * 0.70, s * 0.78], outline="black", width=4)
    d.polygon([(s * 0.27, s * 0.45), (s * 0.50, s * 0.22), (s * 0.73, s * 0.45)],
              outline="black")
    d.rectangle([s * 0.45, s * 0.60, s * 0.55, s * 0.78], outline="black", width=3)  # door
    d.line([s * 0.05, s * 0.78, s * 0.95, s * 0.78], fill="black", width=4)  # ground
    d.ellipse([s * 0.74, s * 0.10, s * 0.90, s * 0.26], outline="black", width=3)  # sun
    return img


def _data_uri(img: Image.Image, size: int, quality: int) -> str:
    img = img.convert("RGB").resize((size, size))
    buf = io.BytesIO()
    img.save(buf, format="JPEG", quality=quality)
    b64 = base64.b64encode(buf.getvalue()).decode("ascii")
    return f"data:image/jpeg;base64,{b64}", len(buf.getvalue())


def _extract_image_bytes(out: dict) -> bytes | None:
    """Pull JPEG/PNG bytes out of a realtime output message (sync_mode → inline)."""
    images = out.get("images") or []
    if not images:
        return None
    img0 = images[0]
    if isinstance(img0, dict):
        content = img0.get("content")
        if isinstance(content, (bytes, bytearray)):
            return bytes(content)
        url = img0.get("url") or ""
        if isinstance(url, str) and url.startswith("data:"):
            return base64.b64decode(url.split(",", 1)[1])
    return None


async def run(args) -> None:
    if not os.environ.get("FAL_KEY"):
        raise SystemExit("FAL_KEY not in env. Run: set -a; . ../backend/.env.local; set +a")

    if args.image:
        base_img = Image.open(args.image)
    else:
        base_img = _synthetic_sketch(args.size)
    data_uri, raw_bytes = _data_uri(base_img, args.size, args.quality)
    print(f"input: {'file ' + args.image if args.image else 'synthetic sketch'} "
          f"-> {args.size}x{args.size} q{args.quality} = {raw_bytes/1024:.0f}KB JPEG "
          f"({len(data_uri)/1024:.0f}KB as data-URI)")

    app = "fal-ai/flux-2/klein/realtime"
    base_args = {
        "image_url": data_uri,
        "prompt": args.prompt,
        "num_inference_steps": args.steps,
        "schedule_mu": args.schedule_mu,
        "output_feedback_strength": args.feedback,
        "image_size": args.image_size,
        "seed": args.seed,
        "sync_mode": True,  # inline bytes back, skip CDN upload (lower latency)
    }
    _shown_path = f"/{args.path.lstrip('/')}" if args.path else ""
    print(f"connecting: wss://fal.run/{app}{_shown_path}  (JWT auto-minted from FAL_KEY)")
    print(f"params: steps={args.steps} schedule_mu={args.schedule_mu} "
          f"feedback={args.feedback} image_size={args.image_size} seed={args.seed}\n")

    t_connect = time.time()
    latencies: list[float] = []
    sent = received = 0
    first_frame_at: float | None = None
    first_out_keys_printed = False
    out_dir = args.out_dir
    os.makedirs(out_dir, exist_ok=True)

    # model id already ends in "/realtime" -> path="" avoids a doubled .../realtime/realtime
    async with fal_client.realtime_async(app, path=args.path) as conn:
        t_open = time.time()
        print(f"WS open after {t_open - t_connect:.2f}s")
        send_interval = 1.0 / args.fps if args.fps > 0 else 0.0
        stop_at = time.time() + args.duration
        pending: dict[int, float] = {}
        done_sending = asyncio.Event()
        state = {"last_send_at": 0.0, "idle_timeout_s": None}

        async def sender():
            nonlocal sent
            while time.time() < stop_at:
                pending[sent] = time.time()
                state["last_send_at"] = time.time()
                # vary seed slightly so frames aren't byte-identical (sim a changing sketch)
                await conn.send({**base_args, "seed": args.seed + (sent % 7)})
                sent += 1
                if send_interval:
                    await asyncio.sleep(send_interval)
            done_sending.set()

        async def receiver():
            nonlocal received, first_frame_at, first_out_keys_printed
            while True:
                if done_sending.is_set() and not pending and not args.measure_idle:
                    break
                try:
                    out = await asyncio.wait_for(conn.recv(), timeout=args.recv_timeout)
                except asyncio.TimeoutError:
                    break
                except fal_client.client.RealtimeError as e:
                    msg = str(e)
                    if "no inputs" in msg or "TIMEOUT" in msg:
                        idle = time.time() - state["last_send_at"]
                        state["idle_timeout_s"] = idle
                        print(f"\n  fal idle TIMEOUT after {idle:.1f}s since last input "
                              f"(\"reconnect when needed\")")
                    else:
                        print(f"\n  RealtimeError: {msg}")
                    break
                if out is None:
                    print("\n  server closed connection (recv None)")
                    break
                now = time.time()
                if not first_out_keys_printed:
                    print(f"  FIRST message keys: {sorted(out.keys())}")
                    if "error" in out or "detail" in out:
                        print(f"  ERROR PAYLOAD: {repr(out)[:600]}")
                    imgs = out.get("images")
                    if imgs and isinstance(imgs[0], dict):
                        print(f"  images[0] keys: {sorted(imgs[0].keys())}, "
                              f"content_type={imgs[0].get('content_type')}")
                    first_out_keys_printed = True
                if first_frame_at is None:
                    first_frame_at = now
                    print(f"  COLD START to first frame: {now - t_connect:.2f}s "
                          f"(connect), {now - t_open:.2f}s (from WS open)")
                if pending:
                    newest = max(pending)
                    latencies.append(now - pending[newest])
                    pending.clear()  # latest-wins; older sends considered dropped
                img_bytes = _extract_image_bytes(out)
                received += 1
                if img_bytes and received <= 3:
                    p = os.path.join(out_dir, f"frame_{received:02d}.jpg")
                    with open(p, "wb") as f:
                        f.write(img_bytes)
                fps = received / (now - t_open) if now > t_open else 0
                size_kb = len(img_bytes) / 1024 if img_bytes else 0
                print(f"  frame {received}: {size_kb:.0f}KB  {fps:.2f} FPS avg", end="\r")

        await asyncio.gather(sender(), receiver())

        elapsed = time.time() - t_open
        print("\n\n=== stream results ===")
        print(f"  duration:        {elapsed:.1f}s @ target {args.fps} FPS in")
        print(f"  frames sent:     {sent}")
        print(f"  frames returned: {received}  (drop ratio {1 - received/sent:.0%})"
              if sent else "")
        print(f"  returned FPS:    {received / elapsed if elapsed else 0:.2f}")
        if first_frame_at:
            print(f"  cold start:      {first_frame_at - t_connect:.2f}s (connect→first frame)")
        if latencies:
            ms = sorted(x * 1000 for x in latencies)
            q = lambda p: ms[min(len(ms) - 1, int(p * len(ms)))]  # noqa: E731
            print(f"  latency ms:      p50={q(0.5):.0f}  p90={q(0.9):.0f}  "
                  f"p99={q(0.99):.0f}  min={ms[0]:.0f}  max={ms[-1]:.0f}  "
                  f"mean={statistics.mean(ms):.0f}")
        print(f"  sample frames:   {out_dir}/frame_01..03.jpg")

        if args.idle_hold > 0:
            print(f"\n=== idle-hold probe: keep socket open idle {args.idle_hold}s ===")
            held_start = time.time()
            closed = False
            try:
                while time.time() - held_start < args.idle_hold:
                    try:
                        m = await asyncio.wait_for(conn.recv(), timeout=5.0)
                        if m is None:
                            held = time.time() - held_start
                            print(f"  WS CLOSED by server after ~{held:.0f}s idle -> idle cap exists")
                            closed = True
                            break
                    except asyncio.TimeoutError:
                        pass
            except Exception as e:  # noqa: BLE001
                held = time.time() - held_start
                print(f"  WS error after ~{held:.0f}s idle: {type(e).__name__}: {e}")
                closed = True
            if not closed:
                try:
                    await conn.send(base_args)
                    out = await asyncio.wait_for(conn.recv(), timeout=args.recv_timeout)
                    ok = _extract_image_bytes(out) is not None
                    print(f"  socket SURVIVED {args.idle_hold}s idle and served another "
                          f"frame (got_image={ok})")
                except Exception as e:  # noqa: BLE001
                    print(f"  socket unusable after idle hold: {type(e).__name__}: {e}")


def main():
    ap = argparse.ArgumentParser(description="fal HOSTED klein realtime probe")
    ap.add_argument("--image", default="", help="sketch path (default: synthetic house)")
    ap.add_argument("--prompt", default="a cozy watercolor painting of a house at sunset")
    ap.add_argument("--steps", type=int, default=3, help="num_inference_steps (1-8)")
    ap.add_argument("--schedule-mu", dest="schedule_mu", type=float, default=2.3)
    ap.add_argument("--feedback", type=float, default=1.0, help="output_feedback_strength 0-1")
    ap.add_argument("--image-size", dest="image_size", default="square",
                    help="square (768) | square_hd (1024)")
    ap.add_argument("--seed", type=int, default=35)
    ap.add_argument("--size", type=int, default=704, help="input JPEG size (fal optimum 704)")
    ap.add_argument("--quality", type=int, default=50, help="input JPEG quality (fal optimum 50)")
    ap.add_argument("--fps", type=float, default=2.0, help="send rate (iPad ~2 FPS)")
    ap.add_argument("--duration", type=float, default=30.0)
    ap.add_argument("--idle-hold", dest="idle_hold", type=float, default=0.0)
    ap.add_argument("--measure-idle", dest="measure_idle", action="store_true",
                    help="after streaming, keep recv()ing to time fal's idle TIMEOUT")
    ap.add_argument("--recv-timeout", dest="recv_timeout", type=float, default=30.0)
    ap.add_argument("--out-dir", dest="out_dir", default="/tmp/fal_klein_probe")
    ap.add_argument("--path", default="", help="WS sub-path (default empty; model id already ends in /realtime)")
    asyncio.run(run(ap.parse_args()))


if __name__ == "__main__":
    main()
