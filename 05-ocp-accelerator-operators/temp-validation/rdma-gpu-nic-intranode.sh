#!/bin/bash
# ============================================================================
# rdma-gpu-nic-intranode.sh - Test GPUDirect RDMA BW within a single node
# ============================================================================
# Runs ib_write_bw between GPU0 and GPUs 1-7 on the SAME pod/node.
# The server uses GPU0's PIX NIC, the client uses each other GPU's PIX NIC.
# Since both ends are in the same pod, uses loopback (127.0.0.1) for the
# TCP control channel.
#
# Usage:
#   ./rdma-gpu-nic-intranode.sh <pod> <namespace>
#
# Example:
#   ./rdma-gpu-nic-intranode.sh shared-roce-macvlan-test-0 llm-d-setup
#
# Prerequisites:
#   - Pod must have 8 GPUs, 10 macvlan NICs, and rdma/shared_roce
#   - gpu-nic-topo.sh must be at /tmp/gpu-nic-topo.sh inside the pod
# ============================================================================

set -euo pipefail

POD="${1:?Usage: $0 <pod> <namespace>}"
NAMESPACE="${2:?}"

GID_INDEX=5
MSG_SIZE=1048576
NUM_ITERS=2000
BASE_PORT=21000

LOG_DIR="rdma-intranode-logs-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOG_DIR"

echo "============================================"
echo "  GPUDirect RDMA Intra-Node BW Test"
echo "============================================"
echo "  Pod:        $POD"
echo "  Namespace:  $NAMESPACE"
echo "  GID index:  $GID_INDEX (RoCEv2)"
echo "  Msg size:   $MSG_SIZE bytes"
echo "  Iterations: $NUM_ITERS"
echo "  Log dir:    $LOG_DIR"
echo ""

filter_roce_nic() {
  local mlx_dev=$1
  local gid
  gid=$(oc exec -n "$NAMESPACE" "$POD" -- cat "/sys/class/infiniband/$mlx_dev/ports/1/gids/$GID_INDEX" 2>/dev/null || echo "")
  if [ -z "$gid" ] || [ "$gid" = "0000:0000:0000:0000:0000:0000:0000:0000" ] || [[ "$gid" == fe80* ]]; then
    return 1
  fi
  return 0
}

find_best_roce_nic() {
  local gpu=$1
  local hcas
  hcas=$(oc exec -n "$NAMESPACE" "$POD" -- bash /tmp/gpu-nic-topo.sh --json 2>/dev/null | \
    python3 -c "
import json, sys
data = json.load(sys.stdin)
for entry in data.get('gpu_nic_topology', []):
    if entry['gpu'] == $gpu:
        for h in entry.get('closest_hcas', []):
            print(h['hca'])
        break
")
  for hca in $hcas; do
    if filter_roce_nic "$hca"; then
      echo "$hca"
      return 0
    fi
  done
  echo "none"
  return 1
}

echo "--- Discovering GPU-NIC topology ---"
echo ""

declare -a NICS
for gpu in $(seq 0 7); do
  nic=$(find_best_roce_nic "$gpu")
  NICS[$gpu]="$nic"
  echo "  GPU $gpu -> $nic"
done

echo ""
echo "--- Running GPU0 vs GPU1-7 intra-node tests ---"
echo ""
printf "%-14s %-10s %-10s %-10s %-10s %-14s %-14s\n" \
  "Test" "Srv GPU" "Srv NIC" "Cli GPU" "Cli NIC" "BW avg Gb/s" "BW peak Gb/s"
printf '%0.s-' $(seq 1 84)
echo ""

srv_gpu=0
s_nic="${NICS[0]}"

if [ "$s_nic" = "none" ]; then
  echo "ERROR: GPU 0 has no RoCE NIC, cannot run tests."
  exit 1
fi

for cg in $(seq 1 7); do
  c_nic="${NICS[$cg]}"

  if [ "$c_nic" = "none" ]; then
    printf "%-14s %-10s %-10s %-10s %-10s %-14s %-14s\n" \
      "gpu0_gpu${cg}" "0" "$s_nic" "$cg" "NO_NIC" "NO_NIC" "NO_NIC"
    continue
  fi

  port=$((BASE_PORT + cg))
  log_prefix="$LOG_DIR/gpu0_gpu${cg}"

  # Start server (GPU0) in background inside the pod
  oc exec -n "$NAMESPACE" "$POD" -- bash -c \
    "ib_write_bw -d $s_nic -x $GID_INDEX --use_cuda=0 \
     --report_gbits -s $MSG_SIZE -n $NUM_ITERS -F -q 1 -p $port 2>&1" \
    </dev/null >"${log_prefix}_server.log" 2>&1 &
  srv_pid=$!

  sleep 2

  # Run client (GPU N) connecting to localhost inside the same pod
  oc exec -n "$NAMESPACE" "$POD" -- bash -c \
    "ib_write_bw -d $c_nic -x $GID_INDEX --use_cuda=$cg \
     --report_gbits -s $MSG_SIZE -n $NUM_ITERS -F -q 1 -p $port \
     127.0.0.1 2>&1" \
    >"${log_prefix}_client.log" 2>&1

  wait $srv_pid 2>/dev/null || true

  bw_avg=$(grep -E '^\s+[0-9]' "${log_prefix}_client.log" | awk '{print $4}')
  bw_peak=$(grep -E '^\s+[0-9]' "${log_prefix}_client.log" | awk '{print $3}')

  if [ -z "$bw_avg" ]; then
    printf "%-14s %-10s %-10s %-10s %-10s %-14s %-14s\n" \
      "gpu0_gpu${cg}" "0" "$s_nic" "$cg" "$c_nic" "FAIL" "FAIL"
    echo "FAIL" > "${log_prefix}_result.txt"
  else
    printf "%-14s %-10s %-10s %-10s %-10s %-14s %-14s\n" \
      "gpu0_gpu${cg}" "0" "$s_nic" "$cg" "$c_nic" "$bw_avg" "$bw_peak"
    echo "${bw_avg} Gb/s" > "${log_prefix}_result.txt"
  fi
done

echo ""
echo "--- Test complete ---"
echo "Intra-node: GPU0 NIC ($s_nic) as server, GPU1-7 NICs as clients."
echo "Same-NIC pairs (gpu0<->gpu0) skipped (loopback on same device is not meaningful)."
echo "Logs saved to: $LOG_DIR/"

# Write summary
{
  echo "# GPUDirect RDMA Intra-Node BW Test Summary"
  echo "# Date: $(date)"
  echo "# Pod: $POD"
  echo "# GID: $GID_INDEX  Size: $MSG_SIZE  Iters: $NUM_ITERS"
  echo ""
  printf "%-14s %-10s %-10s %-10s %-10s %-14s\n" \
    "Test" "Srv GPU" "Srv NIC" "Cli GPU" "Cli NIC" "BW avg Gb/s"
  for cg in $(seq 1 7); do
    f="$LOG_DIR/gpu0_gpu${cg}_result.txt"
    if [ -f "$f" ]; then
      printf "%-14s %-10s %-10s %-10s %-10s %-14s\n" \
        "gpu0_gpu${cg}" "0" "${NICS[0]}" "$cg" "${NICS[$cg]}" "$(cat "$f")"
    fi
  done
} > "$LOG_DIR/summary.txt"

echo "Summary also saved to: $LOG_DIR/summary.txt"
