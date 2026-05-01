"""Send a single video inference request to a video_server WebSocket.

Used during perf experiments on test pods (kiki-vtest-*) to trigger
one inference and capture timing — the iPad doesn't route to test
pods, so we need to hit the WS directly.

Usage (from inside the test pod):
    pip install --break-system-packages websockets pillow
    python3 test_pod_inference_request.py
    python3 test_pod_inference_request.py --profile
    python3 test_pod_inference_request.py --width 512 --height 512 --frames 145
    python3 test_pod_inference_request.py --url ws://other-host:8766/ws

Defaults: 320x320, 49 frames, no profiling, localhost:8766.
"""
import argparse
import asyncio
import base64
import io
import json
import time

from PIL import Image, ImageDraw
import websockets


async def run(url: str, width: int, height: int, frames: int, profile: bool) -> None:
    img = Image.new('RGB', (width, height), (128, 128, 128))
    d = ImageDraw.Draw(img)
    # Add some shapes so it's not pure gray (which can produce odd
    # latents and skew timing).
    d.ellipse([width // 5, height // 5, width * 4 // 5, height * 4 // 5],
              outline=(0, 0, 0), width=3)
    d.line([width // 4, height // 4, width * 3 // 4, height * 3 // 4],
           fill=(0, 0, 0), width=3)
    buf = io.BytesIO()
    img.save(buf, format='JPEG', quality=85)
    img_b64 = base64.b64encode(buf.getvalue()).decode('ascii')

    req = {
        'type': 'video_request',
        'requestId': f'test-pod-{int(time.time())}',
        'prompt': 'a car driving along a winding road, cinematic',
        'seed': 42,
        'image_b64': img_b64,
        'videoWidth': width,
        'videoHeight': height,
        'videoFrames': frames,
        'enableProfiling': profile,
    }

    print(f"[{time.time():.3f}] connecting to {url} ...")
    async with websockets.connect(url, max_size=64 * 1024 * 1024) as ws:
        print(f"[{time.time():.3f}] sending video_request "
              f"(shape={width}x{height}x{frames}, profile={profile})...")
        t0 = time.time()
        await ws.send(json.dumps(req))

        frame_count = 0
        while True:
            try:
                # Long timeout because profiler captures + compile lowering
                # can both take minutes.
                msg = await asyncio.wait_for(ws.recv(), timeout=600)
            except asyncio.TimeoutError:
                print(f"[{time.time():.3f}] timed out waiting for next message after 600s")
                break
            if isinstance(msg, (bytes, bytearray)):
                frame_count += 1
            else:
                try:
                    data = json.loads(msg)
                except Exception:
                    continue
                t = data.get('type', '?')
                if t in ('video_complete', 'video_cancelled', 'video_failed'):
                    elapsed = time.time() - t0
                    print(f"[{time.time():.3f}] {t} after {elapsed:.2f}s "
                          f"(frames={frame_count})")
                    print(f"  payload: {json.dumps(data)[:300]}")
                    break

    if profile:
        # Trace files take a moment to flush to disk
        await asyncio.sleep(3)
        print("\nProfile trace files written to /tmp/ltx-profile-*.json on the pod.")
        print("scp them back with:")
        print("  scp -P <port> -i ~/.ssh/id_ed25519 root@<ip>:/tmp/ltx-profile-*.json ~/Downloads/")


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument('--url', default='ws://localhost:8766/ws',
                   help='WebSocket URL (default: ws://localhost:8766/ws)')
    p.add_argument('--width', type=int, default=320)
    p.add_argument('--height', type=int, default=320)
    p.add_argument('--frames', type=int, default=49)
    p.add_argument('--profile', action='store_true',
                   help='Enable torch.profiler capture for this request')
    args = p.parse_args()
    asyncio.run(run(args.url, args.width, args.height, args.frames, args.profile))


if __name__ == '__main__':
    main()
