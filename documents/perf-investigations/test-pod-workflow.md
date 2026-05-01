# Test pod workflow — fast iteration on pod-side experiments

*For pre-launch perf work, profiler captures, `torch.compile` experiments, and any other change that would otherwise require a full `npm run deploy` cycle (~15–20 min) per iteration.*

---

## Why test pods exist

The production orchestrator provisions video pods with the name prefix `kiki-vsession-*` and reaps anything in that namespace whose `/health` returns not-ready for >60s. That makes risky experiments impossible on production pods — a `pkill` for code reload, a profiler config that takes 30s to set up, a `torch.compile` lowering that pauses warmup for 2 minutes, all look like "unhealthy pod" to the reaper, which terminates and re-provisions.

A **test pod** is a manually-launched pod with the prefix `kiki-vtest-*`. The reaper filters by name prefix, so it's invisible to the orchestrator entirely. We can SSH in, scp code changes, kill+restart the python server, run multi-minute experiments, and the pod stays alive.

This is a **~10× iteration speedup** for pod-side work:

| Workflow | Production pod | Test pod |
|---|---|---|
| Iterate on `video_pipeline.py` change | Edit → `npm run deploy` (sync to all video DCs ~5–10 min) → `railway up` (~1 min) → terminate current pod → wait for new pod (~2–3 min) → wait for warmup (~10s) → test → log capture from RunPod web console. **~15–20 min/iteration.** | Edit → `scp video_pipeline.py` (~5s) → SSH `pkill -f video_server.py` (bash respawns python automatically, ~30s warmup) → `tail -f /tmp/...` → test. **~1–2 min/iteration.** |
| Try a profiler config | Same 15–20 min loop | Same 1–2 min loop |
| `torch.compile` experiment | Crashloop on production pods (Apr 30 incident) | Run live, capture full stdout to disk before death |
| Read live stdout | Have to grab from RunPod web UI after pod dies | `tail -f /proc/$(pgrep -f video_server)/fd/1` |

---

## Cost

Per CLAUDE.md "Cost during dev/testing": negligible. H100 SXM is ~$2/hr ≈ $50/day. Don't tear pods down between iterations to save money — the cost is irrelevant compared to user-revenue scale and iteration friction. Terminate when the experiment is genuinely done.

If you forget about a pod for a week, that's ~$350. Still negligible. Just run `npm run list-test-pods` at the start of each session to check what's alive.

---

## Quick reference

```bash
# Launch a pod (default DC, no extra env)
cd backend && npm run launch-test-pod

# With an experiment env var
cd backend && npm run launch-test-pod -- --env LTX_TORCH_COMPILE=1

# In a specific DC
cd backend && npm run launch-test-pod -- --dc EU-NL-1

# List what's alive
cd backend && npm run list-test-pods

# Tear down when done
cd backend && npm run terminate-test-pod -- <podId>
```

Pods take ~60–120s to come fully online (container start + ssh ports + model load on first warmup). The launch script waits until SSH ports are assigned and prints the SSH command.

---

## Iteration loop (the point of all this)

Once a test pod is running and warmed up:

### 1. Edit code locally

E.g. change something in `flux-klein-server/video_pipeline.py`.

### 2. scp it to the pod

```
scp -P <port> -i ~/.ssh/id_ed25519 \
    flux-klein-server/video_pipeline.py \
    root@<ip>:/workspace/app/
```

(IP and port are printed by `launch-test-pod` and `list-test-pods`.)

### 3. Restart python (bash respawn loop does the rest)

```
ssh root@<ip> -p <port> -i ~/.ssh/id_ed25519 'pkill -f video_server.py'
```

Bash's `while true; do python3 -u video_server.py; sleep 2; done` loop catches the python exit and respawns. Warmup takes ~10s if no other heavy work is in `load()`.

### 4. Watch live logs

```
ssh root@<ip> -p <port> -i ~/.ssh/id_ed25519 'tail -f /proc/$(pgrep -f video_server)/fd/1'
```

`/proc/<pid>/fd/1` is the live stdout descriptor of the python process. Tailing it gives you live output without needing to re-SSH after each respawn.

For longer-lived logs that survive process restart, use the canary pattern: kill the respawn loop entirely, run python with `nohup ... > /tmp/exp.log 2>&1 & disown`, and tail `/tmp/exp.log`.

### 5. Hit the WebSocket directly to test

The pod isn't routed to by the iPad (orchestrator doesn't know about it). To test inference, hit the WebSocket from inside the pod:

```
ssh into the pod
pip install --break-system-packages websockets pillow   # one-time
# Then a small python script that opens ws://localhost:8766/ws and sends a video_request JSON
```

Or write a small `scripts/test-pod-curl.ts` if this becomes routine. (Not built yet; future work if we end up running the same test 10+ times.)

---

## Troubleshooting

**Launch script hangs at "waiting for SSH port assignment"**

Container is still starting. Normal first-time-on-this-volume can take 60–120s. If >5 min, the script gives up — check the RunPod web console for the pod and look for boot errors.

**SSH connection refused**

Wait 30s and retry — sshd inside the container takes a few seconds to start after the bootstrap. If still refused after 1 min, check `/tmp/ssh-bootstrap.log` from the RunPod web console "Logs" tab to see if `ssh-keygen -A` or `service ssh start` failed.

**`pkill` killed the container, not just python**

Shouldn't happen on a test pod since the reaper isn't watching it, BUT: if `PUBLIC_KEY` wasn't set when the pod was launched, the SERVER_LAUNCH branch took the `exec python3` path (production mode), making python PID 1. Killing PID 1 kills the container. The launch script always sets `PUBLIC_KEY` to force dev mode, so this shouldn't happen unless you manually tampered.

**OOM or weird VRAM behavior**

Check `nvidia-smi` over SSH. If something earlier in the session left allocations behind, restarting python (`pkill`) and waiting for the respawn should free everything (CUDA frees memory on process exit).

**Pod went into a bad state**

Easiest recovery: terminate it (`npm run terminate-test-pod -- <id>`) and launch a fresh one. State on the network volume persists across pods.

---

## When NOT to use a test pod

- **Anything that touches user-facing routing.** The iPad routes through the orchestrator; orchestrator doesn't know about test pods. Use a real session for end-to-end tests.
- **Reaper / orchestrator logic itself.** Need a pod that's actually under the orchestrator. Use a real video session.
- **Multi-pod / load testing.** Test pods are single-shot; load testing should mimic the production session pattern.

For everything else (any pod-side code change, any profiler capture, any model experiment), use a test pod.

---

## Related

- `scripts/launch-test-pod.ts`, `terminate-test-pod.ts`, `list-test-pods.ts` — the scripts
- `CLAUDE.md` "Cost during dev/testing" — the cost guidance
- `CLAUDE.md` "SSHing into a running pod" — the dev-mode respawn loop this depends on
- `2026-04-30-torch-compile-canary-playbook.md` — example experiment that needs this workflow
