"""Benchmark harness for the fal image-spike /ws endpoint — SPIKE.

Substitutes for the iPad: opens the raw WebSocket, streams JPEG sketches at a
target cadence (~2 FPS, matching the iPad's capture rate), and measures the
make-or-break numbers from the spike plan:

  - sustained returned FPS + per-frame latency distribution (p50/p90/p99)
  - cold-start: wall time from connect to first generated frame
  - long-held-connection behavior: keep the socket open idle for --idle-hold
    seconds after streaming, to probe undocumented WS idle/max-duration caps
  - frame-drop sanity: frames sent vs frames returned

Speaks the SAME protocol as model-servers/image/server.py (config text frame +
binary JPEG in; frame_meta text + binary JPEG out), so it works against either
the fal /ws endpoint or the original RunPod pod unchanged.

Usage:
    # Against a deployed fal app (URL from `fal deploy` output). The fal WS host
    # is wss://ws.fal.run/<app-id>/ws ; pass --token from the backend token route
    # (or a dev FAL_KEY) so the upgrade authenticates.
    python fal-spike/scripts/bench_stream.py \
        --url wss://ws.fal.run/<your-app-id>/ws \
        --token "$FAL_TOKEN" \
        --image sketch.png --prompt "a watercolor fox" \
        --duration 60 --fps 2 --idle-hold 120

    # Against the original RunPod pod (no token), for an apples-to-apples baseline
    python fal-spike/scripts/bench_stream.py --url ws://<pod-ip>:8766/ws \
        --image sketch.png --prompt "a watercolor fox" --duration 60 --fps 2

Auth note: how fal authorizes a raw-WS upgrade to a PRIVATE app is one of the
open questions (header vs query param vs subprotocol). --token-mode lets you try
each without editing code; default attaches `Authorization: Key <token>`.
"""

from __future__ import annotations

import argparse
import asyncio
import io
import json
import statistics
import time

import websockets
from PIL import Image


def _load_jpeg(path: str, size: int = 768, quality: int = 70) -> bytes:
    img = Image.open(path).convert("RGB").resize((size, size))
    buf = io.BytesIO()
    img.save(buf, format="JPEG", quality=quality)
    return buf.getvalue()


def _connect_kwargs(args) -> dict:
    """Build websockets.connect kwargs, attaching auth per --token-mode."""
    kwargs: dict = {"max_size": 16 * 1024 * 1024}
    url = args.url
    if args.token:
        if args.token_mode == "header":
            kwargs["additional_headers"] = {"Authorization": f"Key {args.token}"}
        elif args.token_mode == "bearer":
            kwargs["additional_headers"] = {"Authorization": f"Bearer {args.token}"}
        elif args.token_mode == "query":
            sep = "&" if "?" in url else "?"
            url = f"{url}{sep}fal_jwt_token={args.token}"
        elif args.token_mode == "subprotocol":
            kwargs["subprotocols"] = [args.token]
    return {"uri": url, **kwargs}


async def _await_ready(ws) -> None:
    """Consume status frames until the server reports ready."""
    while True:
        msg = await ws.recv()
        if isinstance(msg, bytes):
            # Unexpected early binary — push back not possible; just return.
            return
        status = json.loads(msg)
        if status.get("type") == "status" and status.get("status") == "ready":
            return
        if status.get("status") == "error":
            raise RuntimeError(f"server error before ready: {status.get('message')}")


async def run(args) -> None:
    ck = _connect_kwargs(args)
    print(f"connecting to {ck['uri']} (token_mode={args.token_mode if args.token else 'none'}) ...")
    jpeg = _load_jpeg(args.image)
    print(f"input sketch: {args.image} ({len(jpeg)} bytes)")

    t_connect = time.time()
    async with websockets.connect(**ck) as ws:
        await _await_ready(ws)
        t_ready = time.time()
        print(f"server ready after {t_ready - t_connect:.1f}s (connect+warmup wait)")

        await ws.send(json.dumps({
            "type": "config", "prompt": args.prompt, "steps": args.steps, "seed": args.seed,
        }))

        latencies: list[float] = []
        sent = received = 0
        first_frame_at: float | None = None
        send_interval = 1.0 / args.fps if args.fps > 0 else 0.0
        stop_at = time.time() + args.duration
        pending_send_t: dict[int, float] = {}

        async def sender():
            nonlocal sent
            while time.time() < stop_at:
                pending_send_t[sent] = time.time()
                await ws.send(jpeg)
                sent += 1
                if send_interval:
                    await asyncio.sleep(send_interval)

        async def receiver():
            nonlocal received, first_frame_at
            # Expect frame_meta (text) then binary per generated frame.
            while True:
                try:
                    meta_msg = await asyncio.wait_for(ws.recv(), timeout=args.recv_timeout)
                except asyncio.TimeoutError:
                    break
                if isinstance(meta_msg, bytes):
                    # Out-of-order binary without meta; count it loosely.
                    received += 1
                    continue
                meta = json.loads(meta_msg)
                if meta.get("status") == "error":
                    print(f"\n  server error: {meta.get('message')}")
                    continue
                try:
                    payload = await asyncio.wait_for(ws.recv(), timeout=args.recv_timeout)
                except asyncio.TimeoutError:
                    break
                now = time.time()
                if first_frame_at is None:
                    first_frame_at = now
                    print(f"  COLD START to first frame: {now - t_connect:.1f}s "
                          f"(from connect), {now - t_ready:.1f}s (from ready)")
                # Latency vs the most recent send still outstanding (latest-wins,
                # like the server's single-slot buffer).
                if pending_send_t:
                    newest = max(pending_send_t)
                    latencies.append(now - pending_send_t.pop(newest))
                    pending_send_t.clear()  # older sends were dropped server-side
                received += 1
                fps = received / (now - t_ready) if now > t_ready else 0
                print(f"  frame {received}: {len(payload)/1024:.0f}KB  "
                      f"{fps:.2f} FPS avg  queueEmpty={meta.get('queueEmpty')}", end="\r")

        await asyncio.gather(sender(), receiver())

        elapsed = time.time() - t_ready
        print("\n\n=== stream results ===")
        print(f"  duration:        {elapsed:.1f}s @ target {args.fps} FPS in")
        print(f"  frames sent:     {sent}")
        print(f"  frames returned: {received}")
        print(f"  returned FPS:    {received / elapsed if elapsed else 0:.2f}")
        if first_frame_at:
            print(f"  cold start:      {first_frame_at - t_connect:.1f}s (connect→first frame)")
        if latencies:
            ms = sorted(x * 1000 for x in latencies)
            p = lambda q: ms[min(len(ms) - 1, int(q * len(ms)))]  # noqa: E731
            print(f"  latency ms:      p50={p(0.5):.0f}  p90={p(0.9):.0f}  "
                  f"p99={p(0.99):.0f}  max={ms[-1]:.0f}  mean={statistics.mean(ms):.0f}")

        # Long-held connection probe: sit idle and see if fal tears down the WS.
        if args.idle_hold > 0:
            print(f"\n=== idle-hold probe: keeping socket open {args.idle_hold}s ===")
            held_start = time.time()
            try:
                while time.time() - held_start < args.idle_hold:
                    await asyncio.wait_for(ws.recv(), timeout=5.0)
            except asyncio.TimeoutError:
                # No traffic is expected; keep waiting until idle_hold elapses.
                held = time.time() - held_start
                if held < args.idle_hold:
                    # Re-loop via recursion-free sleep until the budget is spent.
                    await asyncio.sleep(min(5.0, args.idle_hold - held))
            except websockets.ConnectionClosed as e:
                held = time.time() - held_start
                print(f"  WS CLOSED by server after ~{held:.0f}s idle "
                      f"(code={e.code}, reason={e.reason!r}) -> idle timeout exists")
                return
            # Verify still alive by sending one more frame.
            try:
                await ws.send(jpeg)
                meta = await asyncio.wait_for(ws.recv(), timeout=args.recv_timeout)
                _ = await asyncio.wait_for(ws.recv(), timeout=args.recv_timeout)
                print(f"  socket SURVIVED {args.idle_hold}s idle and served another frame")
            except Exception as e:  # noqa: BLE001
                print(f"  socket unusable after idle hold: {type(e).__name__}: {e}")


def main():
    ap = argparse.ArgumentParser(description="fal image-spike streaming benchmark")
    ap.add_argument("--url", required=True, help="ws(s):// endpoint, e.g. wss://ws.fal.run/<app>/ws")
    ap.add_argument("--image", required=True, help="input sketch path")
    ap.add_argument("--prompt", default="", help="generation prompt")
    ap.add_argument("--steps", type=int, default=4)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--fps", type=float, default=2.0, help="target send rate (iPad ~2 FPS)")
    ap.add_argument("--duration", type=float, default=60.0, help="seconds to stream")
    ap.add_argument("--idle-hold", type=float, default=0.0,
                    help="after streaming, hold the socket idle this many seconds (WS-cap probe)")
    ap.add_argument("--recv-timeout", type=float, default=30.0)
    ap.add_argument("--token", default="", help="fal JWT or FAL_KEY for private-app WS auth")
    ap.add_argument("--token-mode", default="header",
                    choices=["header", "bearer", "query", "subprotocol"],
                    help="how to attach --token (try variants if upgrade is rejected)")
    asyncio.run(run(ap.parse_args()))


if __name__ == "__main__":
    main()
