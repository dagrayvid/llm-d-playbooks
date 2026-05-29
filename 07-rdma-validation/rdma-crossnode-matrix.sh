#!/bin/bash
# rdma-crossnode-matrix.sh - Run ib_write_bw across all rail pairs between two pods
#
# Usage: ./rdma-crossnode-matrix.sh [SERVER_POD] [CLIENT_POD] [NAMESPACE]

set -uo pipefail

SERVER_POD="${1:-rdma-sriov-xnode-0}"
CLIENT_POD="${2:-rdma-sriov-xnode-1}"
NAMESPACE="${3:-llm-d-setup}"
BASE_PORT=20000
MSG_SIZE=262144
ITERS=100
GID_INDEX=3

LOG_DIR="rdma-matrix-logs-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOG_DIR"

SERVER_NODE=$(oc get pod "$SERVER_POD" -n "$NAMESPACE" -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "unknown")
CLIENT_NODE=$(oc get pod "$CLIENT_POD" -n "$NAMESPACE" -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "unknown")

echo "=== Cross-Node RDMA Matrix Test ==="
echo "  Server pod: $SERVER_POD ($SERVER_NODE)"
echo "  Client pod: $CLIENT_POD ($CLIENT_NODE)"
echo "  Msg size:   $MSG_SIZE  Iters: $ITERS"
echo "  Log dir:    $LOG_DIR"
echo ""

get_vf_map() {
  local pod=$1
  oc exec -n "$NAMESPACE" "$pod" -- bash -c '
    for iface in /sys/class/net/net*; do
      [ -d "$iface" ] || continue
      name=$(basename "$iface")
      ip=$(ip -4 addr show "$name" 2>/dev/null | grep -oP "inet \K[0-9.]+" | head -1)
      [ -n "$ip" ] || continue
      rdma=""
      if [ -d "$iface/device/infiniband" ]; then
        rdma=$(ls "$iface/device/infiniband" 2>/dev/null | head -1)
      fi
      [ -n "$rdma" ] || continue
      second_octet=$(echo "$ip" | cut -d. -f2)
      rail=$((second_octet - 16))
      echo "$rail $rdma $ip $name"
    done | sort -n
  '
}

echo "--- Discovering server VFs ($SERVER_POD) ---"
SERVER_MAP=$(get_vf_map "$SERVER_POD")
echo "$SERVER_MAP" | while read rail dev ip iface; do
  printf "  Rail %d: %-12s %-16s %s\n" "$rail" "$dev" "$ip" "$iface"
done
echo ""

echo "--- Discovering client VFs ($CLIENT_POD) ---"
CLIENT_MAP=$(get_vf_map "$CLIENT_POD")
echo "$CLIENT_MAP" | while read rail dev ip iface; do
  printf "  Rail %d: %-12s %-16s %s\n" "$rail" "$dev" "$ip" "$iface"
done
echo ""

declare -a S_RAILS S_DEVS S_IPS
while read rail dev ip iface; do
  S_RAILS+=("$rail")
  S_DEVS+=("$dev")
  S_IPS+=("$ip")
done <<< "$SERVER_MAP"

declare -a C_RAILS C_DEVS C_IPS
while read rail dev ip iface; do
  C_RAILS+=("$rail")
  C_DEVS+=("$dev")
  C_IPS+=("$ip")
done <<< "$CLIENT_MAP"

cleanup_pods() {
  oc exec -n "$NAMESPACE" "$SERVER_POD" -- bash -c 'killall ib_write_bw 2>/dev/null; true' 2>/dev/null || true
  oc exec -n "$NAMESPACE" "$CLIENT_POD" -- bash -c 'killall ib_write_bw 2>/dev/null; true' 2>/dev/null || true
  sleep 1
}

echo "=== Running ${#S_RAILS[@]}x${#C_RAILS[@]} matrix (Gb/s) ==="
echo ""
header="Cli\\Srv"
for ((s=0; s<${#S_RAILS[@]}; s++)); do
  header+=",rail${S_RAILS[$s]}"
done
echo "$header"

for ((c=0; c<${#C_RAILS[@]}; c++)); do
  printf "rail${C_RAILS[$c]}"

  for ((s=0; s<${#S_RAILS[@]}; s++)); do
    s_dev="${S_DEVS[$s]}"
    s_ip="${S_IPS[$s]}"
    c_dev="${C_DEVS[$c]}"
    port=$((BASE_PORT + c * 10 + s))
    log_prefix="$LOG_DIR/c${C_RAILS[$c]}_s${S_RAILS[$s]}"

    cleanup_pods

    # Start server in background
    oc exec -n "$NAMESPACE" "$SERVER_POD" -- \
      ib_write_bw -d "$s_dev" -x $GID_INDEX --report_gbits -F -s $MSG_SIZE -n $ITERS --perform_warm_up -p $port \
      </dev/null >"${log_prefix}_server.log" 2>&1 &
    srv_pid=$!

    sleep 1

    # Run client (ib_write_bw exits after ITERS completions)
    oc exec -n "$NAMESPACE" "$CLIENT_POD" -- \
      ib_write_bw -d "$c_dev" -x $GID_INDEX --report_gbits -F -s $MSG_SIZE -n $ITERS --perform_warm_up -p $port "$s_ip" \
      >"${log_prefix}_client.log" 2>&1 &
    cli_pid=$!

    # Wait up to 10s for client to finish, then kill and run a short fallback
    for i in $(seq 1 10); do
      if ! kill -0 $cli_pid 2>/dev/null; then break; fi
      sleep 1
    done
    if kill -0 $cli_pid 2>/dev/null; then
      kill $cli_pid 2>/dev/null || true
      kill $srv_pid 2>/dev/null || true
      wait $cli_pid 2>/dev/null || true
      wait $srv_pid 2>/dev/null || true
      # Re-run with tiny iteration count to get a BW number
      cleanup_pods
      oc exec -n "$NAMESPACE" "$SERVER_POD" -- \
        ib_write_bw -d "$s_dev" -x $GID_INDEX --report_gbits -F -s $MSG_SIZE -n 5 -p $port \
        </dev/null >"${log_prefix}_server.log" 2>&1 &
      srv_pid=$!
      sleep 1
      oc exec -n "$NAMESPACE" "$CLIENT_POD" -- \
        ib_write_bw -d "$c_dev" -x $GID_INDEX --report_gbits -F -s $MSG_SIZE -n 5 -p $port "$s_ip" \
        >"${log_prefix}_client.log" 2>&1 || true
      wait $srv_pid 2>/dev/null || true
    else
      wait $cli_pid 2>/dev/null || true
      wait $srv_pid 2>/dev/null || true
    fi

    avg=$(grep -E "^\s+$MSG_SIZE" "${log_prefix}_client.log" 2>/dev/null | awk '{print $4}')
    if [ -z "$avg" ]; then
      printf ",FAIL"
    else
      printf ",%s" "$avg"
    fi
  done
  echo ""
done

echo ""
echo "=== Matrix complete ==="
echo "  Values are BW average in Gb/s (client RDMA-Writes to server)"
echo "  Rows = client TX rail (${CLIENT_POD})"
echo "  Cols = server RX rail (${SERVER_POD})"
echo "  SLOW = < 1 Gb/s | TIMEOUT = no result in 15s"
echo "  Logs: $LOG_DIR/"
