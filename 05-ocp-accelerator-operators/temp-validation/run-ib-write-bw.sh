#!/bin/bash
# Run ib_write_bw between two test pods with aligned GPU-NIC pairs.
#
# Usage:
#   ./run-ib-write-bw.sh [GPU_INDEX] [SERVER_POD] [CLIENT_POD]
#
#   GPU_INDEX:   which in-pod GPU to test (0-based, default 0)
#   SERVER_POD:  pod name for the server (default: shared-roce-4gpu-test-0)
#   CLIENT_POD:  pod name for the client (default: shared-roce-4gpu-test-2)
#
# Examples:
#   # Default: GPU 0, pod-0 (server) <-> pod-2 (client)
#   ./run-ib-write-bw.sh
#
#   # GPU 2 between specific pods
#   ./run-ib-write-bw.sh 2 shared-roce-4gpu-test-1 shared-roce-4gpu-test-3
#
#   # Works with 8-GPU pods too
#   ./run-ib-write-bw.sh 0 shared-roce-macvlan-test-0 shared-roce-macvlan-test-1
#
# Requires:
#   - gpu-nic-topo.sh in the same directory as this script
#   - Pods must have rdma-tools image with ib_write_bw and nvidia-smi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOPO_SCRIPT="$SCRIPT_DIR/gpu-nic-topo.sh"

NAMESPACE="llm-d-setup"
GPU_INDEX="${1:-0}"
SERVER_POD="${2:-shared-roce-4gpu-test-0}"
CLIENT_POD="${3:-shared-roce-4gpu-test-2}"
PORT=18515
QP=8

echo "=== GPUDirect RDMA ib_write_bw Test ==="
echo "  GPU index (in-pod): $GPU_INDEX"
echo "  Server pod: $SERVER_POD"
echo "  Client pod: $CLIENT_POD"
echo ""

if [ ! -f "$TOPO_SCRIPT" ]; then
  echo "ERROR: gpu-nic-topo.sh not found at $TOPO_SCRIPT"
  exit 1
fi

# Copy gpu-nic-topo.sh into a pod and run it, return JSON topology
get_topo_json() {
  local pod=$1
  echo "  Copying gpu-nic-topo.sh into $pod..." >&2
  oc cp "$TOPO_SCRIPT" "$NAMESPACE/$pod:/tmp/gpu-nic-topo.sh" >/dev/null 2>&1
  echo "  Running gpu-nic-topo.sh --json in $pod..." >&2
  oc exec -n "$NAMESPACE" "$pod" -- bash /tmp/gpu-nic-topo.sh --json 2>/dev/null
}

# Extract the PIX-aligned HCA for a given GPU index from JSON topology
extract_nic() {
  local json="$1"
  local gpu=$2
  echo "$json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for entry in data.get('gpu_nic_topology', []):
    if entry['gpu'] == $gpu:
        hcas = entry.get('closest_hcas', [])
        if hcas:
            print(hcas[0]['hca'])
            break
"
}

# Print full topology from JSON
print_topo() {
  local json="$1"
  echo "$json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for entry in data.get('gpu_nic_topology', []):
    gpu = entry['gpu']
    for hca in entry.get('closest_hcas', []):
        iface = hca.get('interface') or '?'
        ip = hca.get('ip') or 'no IP'
        print(f'  GPU{gpu} <-> {hca[\"hca\"]} ({iface}, {ip}) (PIX)')
"
}

echo "--- Discovering GPU-NIC topology in $SERVER_POD ---"
TOPO_JSON_SERVER=$(get_topo_json "$SERVER_POD")
print_topo "$TOPO_JSON_SERVER"
echo ""

echo "--- Discovering GPU-NIC topology in $CLIENT_POD ---"
TOPO_JSON_CLIENT=$(get_topo_json "$CLIENT_POD")
print_topo "$TOPO_JSON_CLIENT"
echo ""

NIC_SERVER=$(extract_nic "$TOPO_JSON_SERVER" "$GPU_INDEX")
NIC_CLIENT=$(extract_nic "$TOPO_JSON_CLIENT" "$GPU_INDEX")

echo "--- Selected pair for GPU $GPU_INDEX ---"
if [ -z "$NIC_SERVER" ]; then
  echo "  ERROR: No PIX NIC found for GPU $GPU_INDEX in $SERVER_POD"
  exit 1
fi
echo "  $SERVER_POD: GPU $GPU_INDEX <-> $NIC_SERVER (PIX)"

if [ -z "$NIC_CLIENT" ]; then
  echo "  ERROR: No PIX NIC found for GPU $GPU_INDEX in $CLIENT_POD"
  exit 1
fi
echo "  $CLIENT_POD: GPU $GPU_INDEX <-> $NIC_CLIENT (PIX)"
echo ""

echo "--- Pod placement ---"
NODE_SERVER=$(oc get pod -n "$NAMESPACE" "$SERVER_POD" -o jsonpath='{.spec.nodeName}')
NODE_CLIENT=$(oc get pod -n "$NAMESPACE" "$CLIENT_POD" -o jsonpath='{.spec.nodeName}')
echo "  $SERVER_POD -> $NODE_SERVER"
echo "  $CLIENT_POD -> $NODE_CLIENT"
echo ""

SERVER_IP=$(oc get pod -n "$NAMESPACE" "$SERVER_POD" -o jsonpath='{.status.podIP}')

SERVER_CMD="ib_write_bw -d $NIC_SERVER --use_cuda=$GPU_INDEX -a -F -p $PORT -q $QP --report_gbits"
CLIENT_CMD="ib_write_bw -d $NIC_CLIENT --use_cuda=$GPU_INDEX -a -F -p $PORT -q $QP --report_gbits $SERVER_IP"

SERVER_LOG="/tmp/ib-write-bw-server-gpu${GPU_INDEX}.log"
CLIENT_LOG="/tmp/ib-write-bw-client-gpu${GPU_INDEX}.log"

echo "--- ib_write_bw configuration ---"
echo "  Server IP (eth0): $SERVER_IP"
echo "  Port: $PORT"
echo "  Queue pairs: $QP"
echo "  CUDA GPU (in-pod index): $GPU_INDEX"
echo ""
echo "  Server ($SERVER_POD):"
echo "    $SERVER_CMD"
echo ""
echo "  Client ($CLIENT_POD):"
echo "    $CLIENT_CMD"
echo ""
echo "--- Output files ---"
echo "  Server (bandwidth table): $SERVER_LOG"
echo "  Client:                   $CLIENT_LOG"
echo ""
echo "Starting ib_write_bw..."
echo ""

# Start client in background (connects after server is listening)
(
  sleep 4
  oc exec -n "$NAMESPACE" "$CLIENT_POD" -- bash -c "$CLIENT_CMD" > "$CLIENT_LOG" 2>&1
) &
CLIENT_PID=$!

# Server prints bandwidth results live and saves to file
oc exec -n "$NAMESPACE" "$SERVER_POD" -- bash -c "$SERVER_CMD" 2>&1 | tee "$SERVER_LOG"
SERVER_RC=${PIPESTATUS[0]}

wait "$CLIENT_PID" 2>/dev/null || true

if [ "$SERVER_RC" -eq 0 ]; then
  echo ""
  echo "=== Test completed successfully ==="
else
  echo ""
  echo "=== Test FAILED (exit code $SERVER_RC) ==="
  echo ""
  echo "Client output:"
  cat "$CLIENT_LOG" 2>/dev/null || echo "(no output)"
  exit 1
fi
