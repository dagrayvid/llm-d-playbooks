#!/bin/bash
# ============================================================================
# rdma-bw-test.sh - Run ib_write_bw between any two GPU-NIC pairs
# ============================================================================
# Automatically discovers the correct mlx5 device and GID index for each GPU,
# gets the server pod's eth0 IP, and runs the test.
#
# Usage:
#   ./rdma-bw-test.sh <server-pod> <server-gpu> <client-pod> <client-gpu> <namespace> [options]
#
# Examples:
#   # GPU 0 on pod-0 (server) vs GPU 2 on pod-1 (client)
#   ./rdma-bw-test.sh shared-roce-macvlan-test-0 0 shared-roce-macvlan-test-1 2 llm-d-setup
#
#   # Same but with all message sizes
#   ./rdma-bw-test.sh shared-roce-macvlan-test-0 0 shared-roce-macvlan-test-1 2 llm-d-setup -a
#
#   # With GPUDirect disabled (host memory)
#   ./rdma-bw-test.sh shared-roce-macvlan-test-0 0 shared-roce-macvlan-test-1 2 llm-d-setup --no-cuda
#
# Prerequisites:
#   - gpu-nic-topo.sh must be at /tmp/gpu-nic-topo.sh in both pods
# ============================================================================

set -euo pipefail

SERVER_POD="${1:?Usage: $0 <server-pod> <server-gpu> <client-pod> <client-gpu> <namespace> [options]}"
SERVER_GPU="${2:?}"
CLIENT_POD="${3:?}"
CLIENT_GPU="${4:?}"
NAMESPACE="${5:?}"
shift 5

GID_INDEX=5
MSG_SIZE=1048576
NUM_ITERS=2000
PORT=22000
USE_CUDA=true
ALL_SIZES=false
EXTRA_ARGS=""

while [ $# -gt 0 ]; do
  case "$1" in
    -a|--all) ALL_SIZES=true ;;
    --no-cuda) USE_CUDA=false ;;
    -s) shift; MSG_SIZE="$1" ;;
    -n) shift; NUM_ITERS="$1" ;;
    -p) shift; PORT="$1" ;;
    -x) shift; GID_INDEX="$1" ;;
    *) EXTRA_ARGS="$EXTRA_ARGS $1" ;;
  esac
  shift
done

# Resolve GPU -> best RoCE NIC + GID index in a single oc exec call.
# Prints "NIC_NAME GID_INDEX" to stdout.
resolve_gpu_nic() {
  local pod=$1
  local gpu=$2
  oc exec -n "$NAMESPACE" "$pod" -- bash -c '
    gpu='"$gpu"'
    bdf=$(nvidia-smi --query-gpu=pci.bus_id --format=csv,noheader 2>/dev/null | sed -n "$((gpu+1))p" | tr -d " " | tr "[:upper:]" "[:lower:]" | sed "s/^00000000:/0000:/")
    if [ -z "$bdf" ]; then
      echo "ERROR: nvidia-smi returned no BDF for GPU $gpu" >&2
      exit 1
    fi
    gpu_path=$(readlink -f /sys/bus/pci/devices/$bdf 2>/dev/null)
    if [ -z "$gpu_path" ]; then
      echo "ERROR: no sysfs path for $bdf" >&2
      exit 1
    fi
    IFS="/" read -ra gp <<< "${gpu_path#/sys/devices/}"
    [ ${#gp[@]} -ge 5 ] && gpu_sw="${gp[2]}" || gpu_sw="${gp[1]}"
    echo "GPU $gpu BDF=$bdf switch=$gpu_sw" >&2

    # Collect all IPs assigned to this pod so we can match GIDs to our identity
    my_ips=$(ip -4 addr show 2>/dev/null | awk "/inet /{print \$2}" | cut -d/ -f1)
    echo "  Pod IPs: $(echo $my_ips | tr "\n" " ")" >&2

    for rd in /sys/class/infiniband/*; do
      [ -d "$rd" ] || continue
      dev=$(basename "$rd")
      devlink=$(readlink -f "$rd/device" 2>/dev/null) || continue
      pci=$(basename "$devlink")
      np=$(readlink -f /sys/bus/pci/devices/$pci 2>/dev/null)
      IFS="/" read -ra np2 <<< "${np#/sys/devices/}"
      [ ${#np2[@]} -ge 5 ] && nsw="${np2[2]}" || nsw="${np2[1]}"
      [ "$nsw" != "$gpu_sw" ] && continue
      # Scan GID indices; require RoCEv2 type AND IPv4 belonging to THIS pod
      for gf in "$rd/ports/1/gids"/*; do
        [ -f "$gf" ] || continue
        idx=$(basename "$gf")
        gid=$(cat "$gf" 2>/dev/null) || continue
        [ "$gid" = "0000:0000:0000:0000:0000:0000:0000:0000" ] && continue
        [[ "$gid" == fe80* ]] && continue
        # Check GID type -- must be RoCEv2
        gid_type=$(cat "$rd/ports/1/gid_attrs/types/$idx" 2>/dev/null) || continue
        if [[ "$gid_type" != *"v2"* ]]; then
          echo "  -> SKIP: $dev gid_index=$idx type=$gid_type (not RoCEv2)" >&2
          continue
        fi
        # Decode IPv4 from the GID (::ffff:AABB:CCDD)
        if [[ "$gid" =~ 0000:0000:0000:0000:0000:ffff: ]]; then
          hex_ip="${gid##*ffff:}"
          o1=$((16#${hex_ip:0:2}))
          o2=$((16#${hex_ip:2:2}))
          o3=$((16#${hex_ip:5:2}))
          o4=$((16#${hex_ip:7:2}))
          gid_ip="$o1.$o2.$o3.$o4"
          # Check if this IP belongs to this pod
          if echo "$my_ips" | grep -qF "$gid_ip"; then
            echo "  -> MATCH: $dev gid_index=$idx ip=$gid_ip type=RoCEv2 (mine)" >&2
            echo "$dev $idx"
            exit 0
          else
            echo "  -> SKIP: $dev gid_index=$idx ip=$gid_ip type=RoCEv2 (not mine)" >&2
          fi
        fi
      done
      echo "  NIC $dev on same switch but no GID matching this pod" >&2
    done
    echo "ERROR: no RoCE NIC on same PCIe switch as GPU $gpu ($gpu_sw)" >&2
    exit 1
  '
}

echo "--- Resolving GPU-NIC topology ---"

S_RESULT=$(resolve_gpu_nic "$SERVER_POD" "$SERVER_GPU" || true)
C_RESULT=$(resolve_gpu_nic "$CLIENT_POD" "$CLIENT_GPU" || true)

S_NIC=$(echo "$S_RESULT" | awk '{print $1}')
S_GID=$(echo "$S_RESULT" | awk '{print $2}')
C_NIC=$(echo "$C_RESULT" | awk '{print $1}')
C_GID=$(echo "$C_RESULT" | awk '{print $2}')

echo "  Server: $SERVER_POD GPU $SERVER_GPU -> ${S_NIC:-NONE} (gid ${S_GID:-?})"
echo "  Client: $CLIENT_POD GPU $CLIENT_GPU -> ${C_NIC:-NONE} (gid ${C_GID:-?})"

if [ -z "$S_NIC" ]; then
  echo "ERROR: No RoCE NIC found for GPU $SERVER_GPU on $SERVER_POD"
  exit 1
fi
if [ -z "$C_NIC" ]; then
  echo "ERROR: No RoCE NIC found for GPU $CLIENT_GPU on $CLIENT_POD"
  exit 1
fi

# Use discovered GID indices (fall back to CLI-provided value)
S_GID="${S_GID:-$GID_INDEX}"
C_GID="${C_GID:-$GID_INDEX}"

# Get server eth0 IP for TCP control channel
SERVER_ETH0=$(oc exec -n "$NAMESPACE" "$SERVER_POD" -- ip -4 addr show eth0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
if [ -z "$SERVER_ETH0" ]; then
  echo "ERROR: Could not get eth0 IP for $SERVER_POD"
  exit 1
fi

# Build ib_write_bw args (per-side GID index)
S_BASE_ARGS="-x $S_GID --report_gbits -F -q 1 --perform_warm_up -p $PORT"
C_BASE_ARGS="-x $C_GID --report_gbits -F -q 1 --perform_warm_up -p $PORT"
if [ "$ALL_SIZES" = true ]; then
  S_BASE_ARGS="$S_BASE_ARGS -a"
  C_BASE_ARGS="$C_BASE_ARGS -a"
else
  S_BASE_ARGS="$S_BASE_ARGS -s $MSG_SIZE -n $NUM_ITERS"
  C_BASE_ARGS="$C_BASE_ARGS -s $MSG_SIZE -n $NUM_ITERS"
fi
S_BASE_ARGS="$S_BASE_ARGS $EXTRA_ARGS"
C_BASE_ARGS="$C_BASE_ARGS $EXTRA_ARGS"

S_CUDA_ARG=""
C_CUDA_ARG=""
if [ "$USE_CUDA" = true ]; then
  S_CUDA_ARG="--use_cuda=$SERVER_GPU"
  C_CUDA_ARG="--use_cuda=$CLIENT_GPU"
fi

echo ""
echo "============================================"
echo "  ib_write_bw Test"
echo "============================================"
echo "  Server: $SERVER_POD GPU $SERVER_GPU ($S_NIC) gid=$S_GID eth0=$SERVER_ETH0"
echo "  Client: $CLIENT_POD GPU $CLIENT_GPU ($C_NIC) gid=$C_GID"
echo "  CUDA:   $USE_CUDA"
if [ "$ALL_SIZES" = true ]; then
  echo "  Sizes:  all"
else
  echo "  Size:   $MSG_SIZE bytes x $NUM_ITERS iters"
fi
echo "  Port:   $PORT"
echo ""

S_CMD="ib_write_bw -d $S_NIC $S_CUDA_ARG $S_BASE_ARGS"
C_CMD="ib_write_bw -d $C_NIC $C_CUDA_ARG $C_BASE_ARGS $SERVER_ETH0"

echo "Server cmd: $S_CMD"
echo "Client cmd: $C_CMD"
echo ""

# Kill any leftover ib_write_bw on the port
oc exec -n "$NAMESPACE" "$SERVER_POD" -- bash -c "kill \$(lsof -ti :$PORT 2>/dev/null) 2>/dev/null || true" 2>/dev/null || true

# Start server
echo "--- Starting server on $SERVER_POD ---"
oc exec -n "$NAMESPACE" "$SERVER_POD" -- bash -c "$S_CMD" </dev/null &
srv_pid=$!

sleep 2

# Run client
echo "--- Running client on $CLIENT_POD ---"
oc exec -n "$NAMESPACE" "$CLIENT_POD" -- bash -c "$C_CMD"

wait $srv_pid 2>/dev/null || true
echo ""
echo "--- Done ---"
