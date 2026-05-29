#!/bin/bash
# sriov-gpu-nic-map.sh - Fast GPU-to-VF mapping for SR-IOV pods
#
# Discovers which mlx5 RDMA device + GID index to use for each GPU.
# Starts from the pod's net* interfaces (fast) rather than scanning all
# 160+ mlx5 devices in /sys/class/infiniband.
#
# Output (text): GPU <idx> -> <mlx5_X> (net<N>, <IP>, gid_index=<G>)
# Output (json): --json flag for machine consumption
#
# Usage:
#   bash sriov-gpu-nic-map.sh          # human-readable
#   bash sriov-gpu-nic-map.sh --json   # JSON for scripts

set -euo pipefail

MODE="${1:-text}"

get_pcie_switch() {
  local bdf=$1
  local full_path
  full_path=$(readlink -f "/sys/bus/pci/devices/$bdf" 2>/dev/null) || return
  local rel_path=${full_path#/sys/devices/}
  IFS='/' read -ra parts <<< "$rel_path"
  local n=${#parts[@]}
  if [ "$n" -ge 5 ]; then
    echo "${parts[2]}"
  elif [ "$n" -ge 4 ]; then
    echo "${parts[1]}"
  else
    echo "${parts[0]}"
  fi
}

get_rocev2_gid_index() {
  local rdma_dev=$1
  local my_ip=$2
  local gid_dir="/sys/class/infiniband/$rdma_dev/ports/1/gids"
  [ -d "$gid_dir" ] || return
  for gf in "$gid_dir"/*; do
    [ -f "$gf" ] || continue
    local gid
    gid=$(cat "$gf" 2>/dev/null) || continue
    [[ "$gid" =~ 0000:0000:0000:0000:0000:ffff: ]] || continue
    local idx
    idx=$(basename "$gf")
    local gtype
    gtype=$(cat "/sys/class/infiniband/$rdma_dev/ports/1/gid_attrs/types/$idx" 2>/dev/null) || continue
    [[ "$gtype" == *"v2"* ]] || continue
    local hex="${gid##*ffff:}"
    local ip="$((16#${hex:0:2})).$((16#${hex:2:2})).$((16#${hex:5:2})).$((16#${hex:7:2}))"
    if [ "$ip" = "$my_ip" ]; then
      echo "$idx"
      return
    fi
  done
}

# Step 1: Find pod's VF interfaces (net1, net2, ...) -> mlx5 device + IP
declare -A NIC_RDMA   # net1 -> mlx5_X
declare -A NIC_IP     # net1 -> 172.x.x.x
declare -A NIC_PCI    # net1 -> PCI BDF
declare -A NIC_SW     # net1 -> PCIe switch
declare -A NIC_GID    # net1 -> gid_index

for iface in /sys/class/net/net*; do
  [ -d "$iface" ] || continue
  name=$(basename "$iface")

  ip=$(ip -4 addr show "$name" 2>/dev/null | grep -oP 'inet \K[0-9.]+' | head -1)
  [ -n "$ip" ] || continue

  rdma_dev=""
  if [ -d "$iface/device/infiniband" ]; then
    rdma_dev=$(ls "$iface/device/infiniband" 2>/dev/null | head -1)
  fi
  [ -n "$rdma_dev" ] || continue

  pci=$(basename "$(readlink -f "$iface/device" 2>/dev/null)") 2>/dev/null || continue
  sw=$(get_pcie_switch "$pci")

  gid_idx=$(get_rocev2_gid_index "$rdma_dev" "$ip")

  NIC_RDMA[$name]="$rdma_dev"
  NIC_IP[$name]="$ip"
  NIC_PCI[$name]="$pci"
  NIC_SW[$name]="${sw:-unknown}"
  NIC_GID[$name]="${gid_idx:-3}"
done

# Step 2: Find GPUs and their PCIe switches
declare -a GPU_BDF=()
declare -a GPU_SW=()

while IFS= read -r line; do
  bdf=$(echo "$line" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]' | sed 's/^00000000:/0000:/')
  GPU_BDF+=("$bdf")
  GPU_SW+=("$(get_pcie_switch "$bdf")")
done < <(nvidia-smi --query-gpu=pci.bus_id --format=csv,noheader 2>/dev/null)

# Step 3: Match GPUs to NICs by shared PCIe switch
if [ "$MODE" = "--json" ]; then
  echo "["
  first=true
  for ((g=0; g<${#GPU_BDF[@]}; g++)); do
    gsw="${GPU_SW[$g]}"
    for name in $(echo "${!NIC_SW[@]}" | tr ' ' '\n' | sort -V); do
      if [ "${NIC_SW[$name]}" = "$gsw" ]; then
        [ "$first" = true ] && first=false || echo ","
        printf '  {"gpu": %d, "rdma_dev": "%s", "interface": "%s", "ip": "%s", "gid_index": %s, "pci": "%s", "gpu_bdf": "%s"}' \
          "$g" "${NIC_RDMA[$name]}" "$name" "${NIC_IP[$name]}" "${NIC_GID[$name]}" "${NIC_PCI[$name]}" "${GPU_BDF[$g]}"
        break
      fi
    done
  done
  echo ""
  echo "]"
else
  echo "============================================"
  echo "  GPU -> VF Mapping (SR-IOV)"
  echo "============================================"
  echo ""
  printf "  %-6s  %-10s  %-6s  %-16s  %-10s\n" "GPU" "RDMA_DEV" "IFACE" "IP" "GID_INDEX"
  printf "  %-6s  %-10s  %-6s  %-16s  %-10s\n" "------" "----------" "------" "----------------" "----------"

  matched=0
  unmatched_gpus=""
  for ((g=0; g<${#GPU_BDF[@]}; g++)); do
    gsw="${GPU_SW[$g]}"
    found=false
    for name in $(echo "${!NIC_SW[@]}" | tr ' ' '\n' | sort -V); do
      if [ "${NIC_SW[$name]}" = "$gsw" ]; then
        printf "  GPU %-2d  %-10s  %-6s  %-16s  gid=%s\n" \
          "$g" "${NIC_RDMA[$name]}" "$name" "${NIC_IP[$name]}" "${NIC_GID[$name]}"
        found=true
        matched=$((matched + 1))
        break
      fi
    done
    if [ "$found" = false ]; then
      printf "  GPU %-2d  %-10s  %-6s  %-16s  %s\n" \
        "$g" "(none)" "--" "--" "no PIX NIC"
      unmatched_gpus+=" $g"
    fi
  done

  echo ""
  echo "  Matched: $matched/${#GPU_BDF[@]} GPUs have a PIX-aligned VF"

  if [ -n "$unmatched_gpus" ]; then
    echo ""
    echo "  Unmatched GPUs:$unmatched_gpus"
    echo "  (These GPUs have no VF on the same PCIe switch)"
  fi

  echo ""
  echo "  --- All VFs in pod ---"
  for name in $(echo "${!NIC_RDMA[@]}" | tr ' ' '\n' | sort -V); do
    printf "  %-6s  %-10s  %-16s  gid=%-3s  sw=%s\n" \
      "$name" "${NIC_RDMA[$name]}" "${NIC_IP[$name]}" "${NIC_GID[$name]}" "${NIC_SW[$name]}"
  done

  echo ""
  echo "  --- ib_write_bw usage ---"
  echo "  Server: ib_write_bw -d <RDMA_DEV> -x <GID_INDEX> --use_cuda=<GPU> --report_gbits -F -s 8388608 -n 5000 -p 18515"
  echo "  Client: ib_write_bw -d <RDMA_DEV> -x <GID_INDEX> --use_cuda=<GPU> --report_gbits -F -s 8388608 -n 5000 -p 18515 <SERVER_IP>"
fi
