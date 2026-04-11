"""Test client for the FLUX.2-klein WebSocket server.

Usage:
    # Reference mode (native img2img)
    python test_client.py --image sketch.png --prompt "a cat" --mode reference

    # Denoise mode (traditional img2img)
    python test_client.py --image sketch.png --prompt "a cat" --mode denoise --denoise 0.6

    # Burst mode: send N frames and measure throughput
    python test_client.py --image sketch.png --prompt "a cat" --burst 10

    # With fixed seed for consistency
    python test_client.py --image sketch.png --prompt "a cat" --seed 42

    # Connect to remote server
    python test_client.py --url ws://pod-ip:8766/ws --image sketch.png --prompt "a cat"
"""

import argparse
import asyncio
import io
import json
import time

import websockets
from PIL import Image


async def run_test(args):
    print(f"Connecting to {args.url}...")

    async with websockets.connect(args.url, max_size=10 * 1024 * 1024) as ws:
        # Wait for ready status
        msg = await ws.recv()
        status = json.loads(msg)
        print(f"Server status: {status}")

        if status.get("status") != "ready":
            print("Waiting for server to be ready...")
            while True:
                msg = await ws.recv()
                status = json.loads(msg)
                if status.get("status") == "ready":
                    break
            print("Server ready.")

        # Send config
        config = {
            "type": "config",
            "prompt": args.prompt,
            "mode": args.mode,
            "steps": args.steps,
            "seed": args.seed,
        }
        if args.mode == "denoise":
            config["denoise"] = args.denoise
        else:
            config["guidanceScale"] = args.guidance_scale

        await ws.send(json.dumps(config))
        print(f"Config sent: mode={args.mode}, prompt='{args.prompt}', steps={args.steps}")

        # Load and encode input image
        image = Image.open(args.image).convert("RGB").resize((768, 768))
        buffer = io.BytesIO()
        image.save(buffer, format="JPEG", quality=70)
        jpeg_data = buffer.getvalue()
        print(f"Input image: {args.image} ({len(jpeg_data)} bytes)")

        num_frames = args.burst if args.burst else 1
        results_received = 0
        t_start = time.time()

        for i in range(num_frames):
            await ws.send(jpeg_data)

            try:
                response = await asyncio.wait_for(ws.recv(), timeout=30.0)

                if isinstance(response, bytes):
                    results_received += 1
                    size_kb = len(response) / 1024
                    elapsed = time.time() - t_start
                    fps = results_received / elapsed if elapsed > 0 else 0

                    if num_frames == 1:
                        output_path = "output.jpg"
                        with open(output_path, "wb") as f:
                            f.write(response)
                        print(f"Result saved to {output_path} ({size_kb:.1f} KB)")
                        result_img = Image.open(io.BytesIO(response))
                        print(f"Output resolution: {result_img.size}")
                    else:
                        print(
                            f"Frame {i+1}/{num_frames}: "
                            f"received {size_kb:.1f} KB, "
                            f"{fps:.1f} FPS avg",
                            end="\r",
                        )

                elif isinstance(response, str):
                    data = json.loads(response)
                    if data.get("type") == "status" and data.get("status") == "error":
                        print(f"\nServer error: {data.get('message')}")
                    else:
                        print(f"\nServer message: {data}")

            except asyncio.TimeoutError:
                print(f"\nTimeout waiting for frame {i+1}")

        elapsed = time.time() - t_start
        fps = results_received / elapsed if elapsed > 0 else 0

        print(f"\n\nResults:")
        print(f"  Frames sent:     {num_frames}")
        print(f"  Frames received: {results_received}")
        print(f"  Total time:      {elapsed:.2f}s")
        print(f"  Average FPS:     {fps:.1f}")

        if num_frames > 1 and results_received > 0:
            output_path = "output.jpg"
            with open(output_path, "wb") as f:
                f.write(response)
            print(f"  Last frame saved to {output_path}")


def main():
    parser = argparse.ArgumentParser(description="FLUX.2-klein test client")
    parser.add_argument("--url", default="ws://localhost:8766/ws", help="WebSocket URL")
    parser.add_argument("--image", required=True, help="Input image path")
    parser.add_argument("--prompt", default="", help="Generation prompt")
    parser.add_argument("--mode", default="reference", choices=["reference", "denoise"],
                        help="Img2img mode: reference (native) or denoise (traditional)")
    parser.add_argument("--denoise", type=float, default=0.6,
                        help="Denoise strength for denoise mode (0.0-1.0)")
    parser.add_argument("--guidance-scale", type=float, default=4.0,
                        help="Guidance scale for reference mode")
    parser.add_argument("--steps", type=int, default=4, help="Number of inference steps")
    parser.add_argument("--seed", type=int, default=None, help="Random seed for reproducibility")
    parser.add_argument("--burst", type=int, default=0, help="Number of frames to send (0=single)")
    args = parser.parse_args()

    asyncio.run(run_test(args))


if __name__ == "__main__":
    main()
