#!/bin/bash
# Creates a RunPod pod with the existing network volume and sets up ComfyUI.
# Usage: RUNPOD_API_KEY=<key> ./scripts/create-pod.sh [--region eu|us]
#
# Prerequisites: curl, jq
# After running, update Railway: railway vars set COMFYUI_URL=https://<POD_ID>-8188.proxy.runpod.net

set -euo pipefail

REGION="${1:---region}"
REGION_VAL="${2:-eu}"

if [ "$REGION" = "--region" ]; then
  REGION_VAL="${2:-eu}"
elif [ "$1" = "eu" ] || [ "$1" = "us" ]; then
  REGION_VAL="$1"
fi

if [ -z "${RUNPOD_API_KEY:-}" ]; then
  echo "Error: RUNPOD_API_KEY environment variable is required"
  echo "Get your API key from https://www.runpod.io/console/user/settings"
  exit 1
fi

# Check dependencies
for cmd in curl jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: $cmd is required. Install it first."
    exit 1
  fi
done

API_URL="https://api.runpod.io/graphql?api_key=${RUNPOD_API_KEY}"

# Region-specific config
if [ "$REGION_VAL" = "eu" ]; then
  DATACENTER="EU-NL-1"
  echo "Using EU region (eu-nl-1)"
elif [ "$REGION_VAL" = "us" ]; then
  DATACENTER="US-GA-2"
  echo "Using US region (us-ga-2)"
else
  echo "Error: Region must be 'eu' or 'us'"
  exit 1
fi

# Step 1: Find the network volume in the selected region
echo ""
echo "==> Finding network volumes..."
VOLUMES_RESPONSE=$(curl -s "$API_URL" \
  -H 'Content-Type: application/json' \
  -d '{"query": "query { myself { networkVolumes { id name dataCenterId size } } }"}')

echo "$VOLUMES_RESPONSE" | jq -r '.data.myself.networkVolumes[] | "\(.id)\t\(.name)\t\(.dataCenterId)\t\(.size)GB"'

VOLUME_ID=$(echo "$VOLUMES_RESPONSE" | jq -r ".data.myself.networkVolumes[] | select(.dataCenterId == \"$DATACENTER\") | .id" | head -1)

if [ -z "$VOLUME_ID" ] || [ "$VOLUME_ID" = "null" ]; then
  echo "Error: No network volume found in $DATACENTER"
  echo "Available volumes:"
  echo "$VOLUMES_RESPONSE" | jq '.data.myself.networkVolumes'
  exit 1
fi

echo "Found volume: $VOLUME_ID in $DATACENTER"

# Step 2: Create the pod
echo ""
echo "==> Creating pod with H100 80GB SXM..."

CREATE_RESPONSE=$(curl -s "$API_URL" \
  -H 'Content-Type: application/json' \
  -d "{
    \"query\": \"mutation { podFindAndDeployOnDemand(input: { name: \\\"kiki-comfyui\\\", imageName: \\\"runpod/comfyui:latest\\\", gpuTypeId: \\\"NVIDIA H100 80GB HBM3\\\", gpuCount: 1, volumeInGb: 0, containerDiskInGb: 20, networkVolumeId: \\\"${VOLUME_ID}\\\", volumeMountPath: \\\"/workspace\\\", ports: \\\"8188/http,8765/http,22/tcp\\\", dataCenterId: \\\"${DATACENTER}\\\", startSsh: true }) { id machineId imageName desiredStatus } }\"
  }")

POD_ID=$(echo "$CREATE_RESPONSE" | jq -r '.data.podFindAndDeployOnDemand.id // empty')

if [ -z "$POD_ID" ]; then
  echo "Error creating pod:"
  echo "$CREATE_RESPONSE" | jq .

  # If H100 SXM not available, try H100 PCIe or A100
  echo ""
  echo "H100 SXM not available. Trying H100 PCIe..."
  CREATE_RESPONSE=$(curl -s "$API_URL" \
    -H 'Content-Type: application/json' \
    -d "{
      \"query\": \"mutation { podFindAndDeployOnDemand(input: { name: \\\"kiki-comfyui\\\", imageName: \\\"runpod/comfyui:latest\\\", gpuTypeId: \\\"NVIDIA H100 PCIe\\\", gpuCount: 1, volumeInGb: 0, containerDiskInGb: 20, networkVolumeId: \\\"${VOLUME_ID}\\\", volumeMountPath: \\\"/workspace\\\", ports: \\\"8188/http,8765/http,22/tcp\\\", dataCenterId: \\\"${DATACENTER}\\\", startSsh: true }) { id machineId imageName desiredStatus } }\"
    }")

  POD_ID=$(echo "$CREATE_RESPONSE" | jq -r '.data.podFindAndDeployOnDemand.id // empty')

  if [ -z "$POD_ID" ]; then
    echo "H100 PCIe also unavailable. Trying A100 80GB..."
    CREATE_RESPONSE=$(curl -s "$API_URL" \
      -H 'Content-Type: application/json' \
      -d "{
        \"query\": \"mutation { podFindAndDeployOnDemand(input: { name: \\\"kiki-comfyui\\\", imageName: \\\"runpod/comfyui:latest\\\", gpuTypeId: \\\"NVIDIA A100 80GB PCIe\\\", gpuCount: 1, volumeInGb: 0, containerDiskInGb: 20, networkVolumeId: \\\"${VOLUME_ID}\\\", volumeMountPath: \\\"/workspace\\\", ports: \\\"8188/http,8765/http,22/tcp\\\", dataCenterId: \\\"${DATACENTER}\\\", startSsh: true }) { id machineId imageName desiredStatus } }\"
      }")

    POD_ID=$(echo "$CREATE_RESPONSE" | jq -r '.data.podFindAndDeployOnDemand.id // empty')

    if [ -z "$POD_ID" ]; then
      echo "Error: No suitable GPU available in $DATACENTER"
      echo "$CREATE_RESPONSE" | jq .
      exit 1
    fi
  fi
fi

echo "Pod created! ID: $POD_ID"
PROXY_URL="https://${POD_ID}-8188.proxy.runpod.net"
echo "Proxy URL: $PROXY_URL"

# Step 3: Wait for pod to be ready
echo ""
echo "==> Waiting for pod to start..."
for i in $(seq 1 60); do
  POD_STATUS=$(curl -s "$API_URL" \
    -H 'Content-Type: application/json' \
    -d "{\"query\": \"query { pod(input: { podId: \\\"${POD_ID}\\\" }) { id desiredStatus runtime { uptimeInSeconds gpus { id } } } }\"}")

  UPTIME=$(echo "$POD_STATUS" | jq -r '.data.pod.runtime.uptimeInSeconds // 0')

  if [ "$UPTIME" -gt 0 ] 2>/dev/null; then
    echo "Pod is running! (uptime: ${UPTIME}s)"
    break
  fi

  if [ "$i" -eq 60 ]; then
    echo "Timeout waiting for pod to start. Check RunPod console."
    echo "Pod ID: $POD_ID"
    echo "When ready, run: ./scripts/setup-pod.sh $POD_ID"
    exit 1
  fi

  echo "  Waiting... (${i}/60)"
  sleep 5
done

# Step 4: Wait for ComfyUI to be accessible (the template auto-starts it)
echo ""
echo "==> Waiting for ComfyUI to become accessible..."
for i in $(seq 1 60); do
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "${PROXY_URL}/system_stats" 2>/dev/null || echo "000")

  if [ "$HTTP_CODE" = "200" ]; then
    echo "ComfyUI is responding!"
    break
  fi

  if [ "$i" -eq 60 ]; then
    echo "ComfyUI not responding yet. May need manual setup."
    echo "Pod ID: $POD_ID"
    echo "Run: ./scripts/setup-pod.sh $POD_ID"
    exit 1
  fi

  echo "  Waiting for ComfyUI... (HTTP $HTTP_CODE, attempt ${i}/60)"
  sleep 10
done

# Step 5: Check if models are loaded (test with system_stats)
echo ""
echo "==> Checking system stats..."
curl -s "${PROXY_URL}/system_stats" | jq .

# Output summary
echo ""
echo "============================================"
echo "  Pod deployment complete!"
echo "============================================"
echo "  Pod ID:    $POD_ID"
echo "  Proxy URL: $PROXY_URL"
echo "  Web UI:    $PROXY_URL"
echo ""
echo "  Next steps:"
echo "  1. SSH into the pod and run the setup script:"
echo "     ./scripts/setup-pod.sh"
echo "     (symlinks models from network volume, installs deps)"
echo ""
echo "  2. Update Railway:"
echo "     cd backend && railway vars set COMFYUI_URL=$PROXY_URL"
echo ""
echo "  3. Verify end-to-end:"
echo "     curl https://kiki-backend-production-eb81.up.railway.app/health"
echo "============================================"
