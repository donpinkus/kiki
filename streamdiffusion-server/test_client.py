"""Test client for the StreamDiffusion WebSocket server.

Usage:
    # Single image roundtrip
    python test_client.py --image sketch.png --prompt "a cat" --t-index-list 10,20

    # Burst mode: send N frames and measure throughput
    python test_client.py --image sketch.png --prompt "a cat" --burst 30

    # Different t_index_list (more creative)
    python test_client.py --image sketch.png --prompt "a cat" --t-index-list 5,15

    # Connect to remote server
    python test_client.py --url ws://pod-ip:8765/ws --image sketch.png --prompt "a cat"
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
        t_index_list = [int(x) for x in args.t_index_list.split(",")]
        config = {
            "type": "config",
            "prompt": args.prompt,
            "tIndexList": t_index_list,
            "width": 512,
            "height": 512,
        }
        await ws.send(json.dumps(config))
        print(f"Config sent: prompt='{args.prompt}', tIndexList={t_index_list}")

        # Load and encode input image
        image = Image.open(args.image).convert("RGB").resize((512, 512))
        buffer = io.BytesIO()
        image.save(buffer, format="JPEG", quality=70)
        jpeg_data = buffer.getvalue()
        print(f"Input image: {args.image} ({len(jpeg_data)} bytes)")

        num_frames = args.burst if args.burst else 1
        switch_at = num_frames // 2 if args.switch_prompt else None
        results_received = 0
        t_start = time.time()

        for i in range(num_frames):
            # Switch prompt mid-stream if requested
            if switch_at and i == switch_at:
                switch_config = {
                    "type": "config",
                    "prompt": args.switch_prompt,
                    "tIndexList": t_index_list,
                }
                await ws.send(json.dumps(switch_config))
                print(f"\n--- Prompt switched to: '{args.switch_prompt}' at frame {i} ---\n")

            # Send frame
            await ws.send(jpeg_data)

            # Wait for response
            try:
                response = await asyncio.wait_for(ws.recv(), timeout=10.0)

                if isinstance(response, bytes):
                    results_received += 1
                    size_kb = len(response) / 1024
                    elapsed = time.time() - t_start
                    fps = results_received / elapsed if elapsed > 0 else 0

                    if num_frames == 1:
                        # Save single result
                        output_path = "output.jpg"
                        with open(output_path, "wb") as f:
                            f.write(response)
                        print(f"Result saved to {output_path} ({size_kb:.1f} KB)")

                        # Verify it's a valid image
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
        print(f"  Frames skipped:  {num_frames - results_received}")
        print(f"  Total time:      {elapsed:.2f}s")
        print(f"  Average FPS:     {fps:.1f}")

        # Save last result in burst mode
        if num_frames > 1 and results_received > 0:
            output_path = "output.jpg"
            with open(output_path, "wb") as f:
                f.write(response)
            print(f"  Last frame saved to {output_path}")


def main():
    parser = argparse.ArgumentParser(description="StreamDiffusion test client")
    parser.add_argument("--url", default="ws://localhost:8765/ws", help="WebSocket URL")
    parser.add_argument("--image", required=True, help="Input image path")
    parser.add_argument("--prompt", default="", help="Generation prompt")
    parser.add_argument("--t-index-list", default="20,30", help="Comma-separated t_index_list (e.g. 10,20 or 5,15,25)")
    parser.add_argument("--burst", type=int, default=0, help="Number of frames to send (0=single)")
    parser.add_argument("--switch-prompt", default=None, help="Switch to this prompt mid-stream")
    args = parser.parse_args()

    asyncio.run(run_test(args))


if __name__ == "__main__":
    main()
