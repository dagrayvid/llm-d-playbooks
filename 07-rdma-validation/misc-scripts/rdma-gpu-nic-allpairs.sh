#!/bin/bash
# ============================================================================
# rdma-gpu-nic-allpairs.sh - Test GPUDirect RDMA BW for all GPU-NIC pairs
# ============================================================================
# Runs ib_write_bw between every GPU-NIC pair on two pods (8x8 = 64 tests).
# Each test uses the PIX (same PCIe switch) NIC for each GPU.
#
# Usage:
#   ./rdma-gpu-nic-allpairs.sh <server-pod> <client-pod> <namespace> <server-eth0-ip>
#
# Example:
#   ./rdma-gpu-nic-allpairs.sh shared-roce-macvlan-test-0 shared-roce-macvlan-test-1 llm-d-setup 10.128.0.179
#
# Prerequisites:
#   - Both pods must have 8 GPUs, 10 macvlan NICs, and rdma/shared_roce
#   - Run gpu-nic-topo.sh --json on each pod first to get the mapping
# ============================================================================

set -euo pipefail

SERVER_POD="${1:?Usage: $0 <server-pod> <client-pod> <namespace> <server-eth0-ip>}"
CLIENT_POD="${2:?}"
NAMESPACE="${3:?}"
SERVER_ETH0="${4:?}"

GID_INDEX=5
MSG_SIZE=1048576
NUM_ITERS=2000
BASE_PORT=20000

LOG_DIR="rdma-allpairs-logs-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOG_DIR"

echo "============================================"
echo "  GPUDirect RDMA All-Pairs BW Test"
echo "============================================"
echo "  Server pod: $SERVER_POD"
echo "  Client pod: $CLIENT_POD"
echo "  Namespace:  $NAMESPACE"
echo "  Server eth0: $SERVER_ETH0"
echo "  GID index:  $GID_INDEX (RoCEv2)"
echo "  Msg size:   $MSG_SIZE bytes"
echo "  Iterations: $NUM_ITERS"
echo "  Log dir:    $LOG_DIR"
echo ""

get_gpu_nic_map() {
  local pod=$1
  oc exec -n "$NAMESPACE" "$pod" -- bash /tmp/gpu-nic-topo.sh --json 2>/dev/null | \
    python3 -c "
import json, sys
data = json.load(sys.stdin)
topo = data.get('gpu_nic_topology', [])
for entry in topo:
    gpu = entry['gpu']
    hcas = entry.get('closest_hcas', [])
    # Pick the first HCA that has a valid RoCEv2 GID (skip non-RoCE devices)
    print(f\"{gpu}:{hcas[0]['hca'] if hcas else 'none'}\")
"
}

filter_roce_nic() {
  local pod=$1
  local mlx_dev=$2
  local gid
  gid=$(oc exec -n "$NAMESPACE" "$pod" -- cat "/sys/class/infiniband/$mlx_dev/ports/1/gids/$GID_INDEX" 2>/dev/null || echo "")
  if [ -z "$gid" ] || [ "$gid" = "0000:0000:0000:0000:0000:0000:0000:0000" ] || [[ "$gid" == fe80* ]]; then
    return 1
  fi
  return 0
}

find_best_roce_nic() {
  local pod=$1
  local gpu=$2
  local hcas
  hcas=$(oc exec -n "$NAMESPACE" "$pod" -- bash /tmp/gpu-nic-topo.sh --json 2>/dev/null | \
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
    if filter_roce_nic "$pod" "$hca"; then
      echo "$hca"
      return 0
    fi
  done
  echo "none"
  return 1
}

echo "--- Discovering GPU-NIC topology ---"
echo ""
echo "Server ($SERVER_POD):"

declare -a SERVER_NICS
for gpu in $(seq 0 7); do
  nic=$(find_best_roce_nic "$SERVER_POD" "$gpu")
  SERVER_NICS[$gpu]="$nic"
  echo "  GPU $gpu -> $nic"
done

echo ""
echo "Client ($CLIENT_POD):"

declare -a CLIENT_NICS
for gpu in $(seq 0 7); do
  nic=$(find_best_roce_nic "$CLIENT_POD" "$gpu")
  CLIENT_NICS[$gpu]="$nic"
  echo "  GPU $gpu -> $nic"
done

echo ""
echo "--- Running 8x8 GPUDirect RDMA BW tests ---"
echo ""
printf "%-12s" "Srv\Cli"
for cg in $(seq 0 7); do
  printf "%-12s" "GPU$cg"
done
echo ""
printf '%0.s-' $(seq 1 108)
echo ""

for sg in $(seq 0 7); do
  printf "%-12s" "GPU$sg"
  s_nic="${SERVER_NICS[$sg]}"

  if [ "$s_nic" = "none" ]; then
    for cg in $(seq 0 7); do printf "%-12s" "NO_NIC"; done
    echo ""
    continue
  fi

  for cg in $(seq 0 7); do
    c_nic="${CLIENT_NICS[$cg]}"

    if [ "$c_nic" = "none" ]; then
      printf "%-12s" "NO_NIC"
      continue
    fi

    port=$((BASE_PORT + sg * 10 + cg))
    log_prefix="$LOG_DIR/sg${sg}_cg${cg}"

    # Start server in background, capture output
    oc exec -n "$NAMESPACE" "$SERVER_POD" -- \
      ib_write_bw -d "$s_nic" -x $GID_INDEX --use_cuda=$sg \
      --report_gbits -s $MSG_SIZE -n $NUM_ITERS -F -q 1 -p $port \
      </dev/null >"${log_prefix}_server.log" 2>&1 &
    srv_pid=$!

    sleep 1

    # Run client and capture full output
    oc exec -n "$NAMESPACE" "$CLIENT_POD" -- \
      ib_write_bw -d "$c_nic" -x $GID_INDEX --use_cuda=$cg \
      --report_gbits -s $MSG_SIZE -n $NUM_ITERS -F -q 1 -p $port \
      "$SERVER_ETH0" >"${log_prefix}_client.log" 2>&1

    wait $srv_pid 2>/dev/null || true

    bw=$(grep -E '^\s+[0-9]' "${log_prefix}_client.log" | awk '{print $4}')

    if [ -z "$bw" ]; then
      printf "%-12s" "FAIL"
      echo "FAIL" > "${log_prefix}_result.txt"
    else
      printf "%-12s" "${bw}"
      echo "${bw} Gb/s" > "${log_prefix}_result.txt"
    fi
  done
  echo ""
done

echo ""
echo "--- Test complete ---"
echo "All values in Gb/sec. Expected ~392 for PIX pairs."
echo "Logs saved to: $LOG_DIR/"
echo "  *_server.log  - full ib_write_bw server output"
echo "  *_client.log  - full ib_write_bw client output"
echo "  *_result.txt  - extracted BW value"

# Write summary
{
  echo "# GPUDirect RDMA All-Pairs BW Test Summary"
  echo "# Date: $(date)"
  echo "# Server: $SERVER_POD  Client: $CLIENT_POD"
  echo "# GID: $GID_INDEX  Size: $MSG_SIZE  Iters: $NUM_ITERS"
  echo ""
  printf "%-12s" "Srv\Cli"
  for cg in $(seq 0 7); do printf "%-12s" "GPU$cg"; done
  echo ""
  for sg in $(seq 0 7); do
    printf "%-12s" "GPU$sg"
    for cg in $(seq 0 7); do
      f="$LOG_DIR/sg${sg}_cg${cg}_result.txt"
      if [ -f "$f" ]; then
        printf "%-12s" "$(cat "$f")"
      else
        printf "%-12s" "N/A"
      fi
    done
    echo ""
  done
} > "$LOG_DIR/summary.txt"

echo ""
echo "Summary also saved to: $LOG_DIR/summary.txt"
