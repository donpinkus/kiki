"""V3 — walk UP the stack to find the first non-builtin Python frame
(i.e., one with a file path), AND also count occurrences of file
fragments anywhere in the stack.

The deepest frame is usually a C-level builtin like `<built-in method
to of Tensor object>` which doesn't tell us anything. The interesting
frame is a few levels up — the Python source file that called .to() in
the first place.
"""
import sys
from collections import defaultdict, Counter

import ijson  # type: ignore

COPY_OPS = {
    'aten::copy_',
    'aten::to',
    'aten::_to_copy',
}

def is_builtin_frame(name: str) -> bool:
    return name.startswith('<built-in') or name.startswith('<method-wrapper')

def main(path: str) -> None:
    by_tid_ts = defaultdict(list)
    total = 0
    with open(path, 'rb') as f:
        for e in ijson.items(f, 'traceEvents.item'):
            total += 1
            if total % 500000 == 0:
                print(f"# parsed {total:,} events so far...", file=sys.stderr)
            if e.get('ph') != 'X':
                continue
            cat = e.get('cat', '')
            if cat not in ('cpu_op', 'python_function'):
                continue
            ts = e.get('ts')
            dur = e.get('dur')
            if ts is None or dur is None:
                continue
            tid = e.get('tid')
            name = e.get('name', '')
            if cat == 'cpu_op' and name not in COPY_OPS:
                continue
            by_tid_ts[tid].append((ts, dur, cat, name))

    print(f"# total trace events: {total:,}", file=sys.stderr)

    # Walk per-tid sorted by ts. Maintain stack of python_function frames.
    by_first_pyframe_count = Counter()
    by_first_pyframe_dur = Counter()
    fragment_dur = Counter()  # any file fragment ANYWHERE in stack
    fragment_count = Counter()
    total_copy_count = 0
    total_copy_dur = 0
    deep_examples = []  # save a few full stacks for inspection

    fragments = ['fp8_cast', 'fp8_scaled', 'quantization', 'ltx_pipelines',
                 'ltx_core', 'transformers', 'flash_attn', 'video_pipeline',
                 'embeddings_processor', 'prompt_encoder', 'image_conditioner',
                 'video_decoder', 'upsampler', 'stage', 'denoiser', 'gpu_model',
                 'huggingface', 'gemma', 'safetensors', 'video_vae', 'patchifiers',
                 'conditioning', 'symphonix', 'distilled', 'pipeline', 'transformer',
                 'load']

    for tid, events in by_tid_ts.items():
        events.sort(key=lambda x: (x[0], -x[1]))
        stack = []  # list of (end_ts, name) for python_function frames
        for ts, dur, cat, name in events:
            end_ts = ts + dur
            while stack and stack[-1][0] <= ts:
                stack.pop()
            if cat == 'python_function':
                stack.append((end_ts, name))
            elif cat == 'cpu_op':
                total_copy_count += 1
                total_copy_dur += dur
                # Walk stack from deepest to shallowest, find first non-builtin
                first_py = None
                for end, frame_name in reversed(stack):
                    if not is_builtin_frame(frame_name):
                        first_py = frame_name
                        break
                if first_py is None:
                    first_py = '<all-builtins>'
                by_first_pyframe_count[first_py] += 1
                by_first_pyframe_dur[first_py] += dur

                # Fragment matching across the WHOLE stack
                stack_text = ' | '.join(f for _, f in stack)
                stack_lower = stack_text.lower()
                matched_frags = set()
                for frag in fragments:
                    if frag.lower() in stack_lower:
                        matched_frags.add(frag)
                for frag in matched_frags:
                    fragment_count[frag] += 1
                    fragment_dur[frag] += dur
                if not matched_frags:
                    fragment_count['<no-fragment-match>'] += 1
                    fragment_dur['<no-fragment-match>'] += dur

                # Save a few example stacks
                if len(deep_examples) < 5 and len(stack) > 3:
                    deep_examples.append(stack_text[:600])

    print(f"\n=== copy/cast totals ===")
    print(f"  total events:        {total_copy_count:,}")
    print(f"  total CPU time:      {total_copy_dur/1000:.1f} ms")

    print(f"\n=== top 40 first-non-builtin Python callers by total time ===")
    print(f"{'caller':<100} {'count':>8} {'total ms':>10}")
    for caller, dur in sorted(by_first_pyframe_dur.items(), key=lambda x: -x[1])[:40]:
        n = by_first_pyframe_count[caller]
        c = caller[:100] if len(caller) <= 100 else caller[:97] + '...'
        print(f"{c:<100} {n:>8} {dur/1000:>10.1f}")

    print(f"\n=== fragment matches (any frame in stack) ===")
    print(f"NOTE: a single copy can match multiple fragments — totals will exceed 100%")
    print(f"{'fragment':<30} {'count':>10} {'total ms':>10} {'% of copy time':>15}")
    for frag, dur in sorted(fragment_dur.items(), key=lambda x: -x[1]):
        pct = (dur / total_copy_dur * 100) if total_copy_dur else 0
        print(f"{frag:<30} {fragment_count[frag]:>10} {dur/1000:>10.1f} {pct:>14.1f}%")

    print(f"\n=== example stack traces (first 5 with depth > 3) ===")
    for i, ex in enumerate(deep_examples):
        print(f"\n[{i+1}] {ex}")


if __name__ == '__main__':
    main(sys.argv[1])
