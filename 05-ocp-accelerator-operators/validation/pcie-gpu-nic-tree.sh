#!/bin/bash
# ============================================================================
# pcie-gpu-nic-tree.sh - PCIe switch topology for GPUs and RDMA NICs
# ============================================================================
# Shows which GPUs and NICs share a PCIe switch (PIX relationship).
# Uses sysfs only -- no pciutils required.
#
# Run inside a privileged pod with hostNetwork:
#   oc cp validation/pcie-gpu-nic-tree.sh <ns>/<pod>:/tmp/
#   oc exec -n <ns> <pod> -- bash /tmp/pcie-gpu-nic-tree.sh
#
# Or via oc debug:
#   oc debug node/<node> -- chroot /host bash < validation/pcie-gpu-nic-tree.sh
# ============================================================================

set -euo pipefail

DATA=$(mktemp)
trap "rm -f $DATA" EXIT

strip_domain() { echo "${1#0000:}"; }

gpu_model() {
  case "$1" in
    2901) echo "B200" ;; 2920) echo "B100" ;; 2941) echo "GB200" ;;
    3182) echo "B300" ;; 31a1) echo "GB300" ;;
    2330) echo "H100 SXM5" ;; 2331) echo "H100 PCIe" ;;
    2335) echo "H200 SXM" ;; 233b) echo "H200 NVL" ;;
    20b2) echo "A100 SXM4" ;; 20b5) echo "A100 PCIe" ;;
    26b9) echo "L40S" ;; 27b8) echo "L4" ;;
    *) echo "GPU($1)" ;;
  esac
}

# Trace PCIe hierarchy for a device.
# Returns: root_port|switch_upstream|downstream_port
trace_pci() {
  local full_path
  full_path=$(readlink -f "/sys/bus/pci/devices/$1")
  local rel_path=${full_path#/sys/devices/}

  local IFS='/'
  local parts=($rel_path)
  local n=${#parts[@]}

  if [ "$n" -ge 5 ]; then
    echo "${parts[1]}|${parts[2]}|${parts[3]}"
  elif [ "$n" -ge 4 ]; then
    echo "${parts[1]}|${parts[1]}|${parts[2]}"
  else
    echo "${parts[1]}|${parts[1]}|${parts[1]}"
  fi
}

# --- Discover GPUs ---
gpu_idx=0
for dev in /sys/bus/pci/devices/*; do
  vendor=$(cat "$dev/vendor" 2>/dev/null || echo none)
  [ "$vendor" != "0x10de" ] && continue
  class=$(cat "$dev/class" 2>/dev/null || echo 0x000000)
  case $class in
    0x030000|0x030200*)
      pci=$(basename "$dev")
      devid=$(cat "$dev/device" 2>/dev/null || echo 0x0000)
      devid=${devid#0x}
      numa=$(cat "$dev/numa_node" 2>/dev/null || echo -1)
      model=$(gpu_model "$devid")

      IFS='|' read -r root_port switch downstream <<< "$(trace_pci "$pci")"
      printf '%s|%s|%s|%s|%s|GPU|GPU %d|%s\n' \
        "$numa" "$switch" "$root_port" "$downstream" "$pci" "$gpu_idx" "$model" >> "$DATA"
      gpu_idx=$((gpu_idx + 1))
      ;;
  esac
done

# --- Discover RDMA NICs (PFs only) ---
for rd in /sys/class/infiniband/*; do
  [ -d "$rd" ] || continue
  [ -L "$rd/device/physfn" ] && continue

  rdma_dev=$(basename "$rd")
  pci_path=$(readlink -f "$rd/device" 2>/dev/null) || continue
  pci=$(basename "$pci_path")
  link_layer=$(cat "$rd/ports/1/link_layer" 2>/dev/null || echo unknown)
  numa=$(cat "$rd/device/numa_node" 2>/dev/null || echo -1)
  netdev=$(ls "$rd/device/net" 2>/dev/null | head -1)
  [ -z "$netdev" ] && netdev="--"
  speed=$(cat "/sys/class/net/$netdev/speed" 2>/dev/null || echo 0)

  ll_tag="RoCE"
  [ "$link_layer" = "InfiniBand" ] && ll_tag="IB"

  if [ "$speed" -gt 0 ] 2>/dev/null; then
    speed_g="$((speed / 1000))G"
  else
    speed_g=""
  fi

  ip=$(ip -4 addr show "$netdev" 2>/dev/null | grep -oP 'inet \K[0-9.]+' | head -1 || true)

  detail="$netdev"
  [ -n "$speed_g" ] && detail="$detail, $speed_g"
  detail="$detail, $ll_tag"
  [ -n "$ip" ] && detail="$detail, $ip"

  IFS='|' read -r root_port switch downstream <<< "$(trace_pci "$pci")"
  printf '%s|%s|%s|%s|%s|NIC|%s|%s\n' \
    "$numa" "$switch" "$root_port" "$downstream" "$pci" "$rdma_dev" "$detail" >> "$DATA"
done

if [ ! -s "$DATA" ]; then
  echo "No GPUs or RDMA NICs found."
  exit 0
fi

# --- Print tree ---
HOSTNAME=$(cat /proc/sys/kernel/hostname 2>/dev/null || echo unknown)
echo "============================================"
echo "  PCIe GPU/NIC Topology: $HOSTNAME"
echo "============================================"
echo ""

sorted=$(sort -t'|' -k1,1n -k2,2 -k5,5 "$DATA")

prev_numa=""
prev_switch=""

while IFS='|' read -r numa switch root_port downstream pci dtype name detail; do
  # NUMA header
  if [ "$numa" != "$prev_numa" ]; then
    [ -n "$prev_numa" ] && echo ""
    echo "NUMA $numa"
    prev_switch=""
    prev_numa="$numa"
  fi

  # Switch header
  if [ "$switch" != "$prev_switch" ]; then
    if [ "$switch" = "$root_port" ]; then
      echo "├── Root port $(strip_domain "$root_port")"
    else
      echo "├── Switch $(strip_domain "$switch") (root $(strip_domain "$root_port"))"
    fi
    prev_switch="$switch"
  fi

  # Device line
  short_down=$(strip_domain "$downstream")
  short_pci=$(strip_domain "$pci")

  if [ "$dtype" = "GPU" ]; then
    printf '│   ├── %s → %s  %-7s (%s)\n' "$short_down" "$short_pci" "$name" "$detail"
  else
    printf '│   ├── %s → %s  %-7s (%s)\n' "$short_down" "$short_pci" "$name" "$detail"
  fi
done <<< "$sorted"

echo "│"
echo ""
