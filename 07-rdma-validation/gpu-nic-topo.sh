#!/bin/bash
# ============================================================================
# gpu-nic-topo.sh - Map GPUs to their closest NICs (PIX = same PCIe switch)
# ============================================================================
# Usage: gpu-nic-topo.sh [--json]
#
# Run inside a pod with GPU access and RDMA devices visible.
# Uses sysfs to trace PCIe hierarchy and find GPUs and NICs that share the
# same upstream PCIe switch (PIX relationship). No nvidia-smi topo parsing.
#
# The GPU index is the CUDA-visible index (matching nvidia-smi ordering),
# so it works correctly in pods with a subset of GPUs.
# ============================================================================

set -euo pipefail

OUTPUT_FORMAT="${1:-text}"

# Trace the PCIe hierarchy for a device BDF and return the upstream switch BDF.
# Two devices sharing the same upstream switch are PIX to each other.
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

# Build JSON array of GPU -> NIC mappings using sysfs PCIe topology.
build_gpu_hca_mapping() {
  # Discover GPUs: get CUDA-ordered PCI BDFs from nvidia-smi
  local gpu_bdfs=()
  while IFS= read -r line; do
    local bdf
    bdf=$(echo "$line" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    bdf=$(echo "$bdf" | sed 's/^00000000:/0000:/')
    gpu_bdfs+=("$bdf")
  done < <(nvidia-smi --query-gpu=pci.bus_id --format=csv,noheader 2>/dev/null)

  if [ ${#gpu_bdfs[@]} -eq 0 ]; then
    echo "[]"
    return
  fi

  # Build GPU index -> PCIe switch map
  local gpu_switches=()
  for bdf in "${gpu_bdfs[@]}"; do
    gpu_switches+=("$(get_pcie_switch "$bdf")")
  done

  # Discover RDMA NICs and their PCIe switches
  local nic_names=()
  local nic_switches=()
  local nic_ifaces=()
  local nic_ips=()

  for rd in /sys/class/infiniband/*; do
    [ -d "$rd" ] || continue
    local rdma_dev
    rdma_dev=$(basename "$rd")
    local pci_path
    pci_path=$(readlink -f "$rd/device" 2>/dev/null) || continue
    local pci
    pci=$(basename "$pci_path")
    local sw
    sw=$(get_pcie_switch "$pci")

    # Find the net interface for this RDMA device.
    # Method 1: sysfs device/net (works for physical interfaces)
    local netdev=""
    local ip=""
    if [ -d "$rd/device/net" ]; then
      netdev=$(ls "$rd/device/net" 2>/dev/null | head -1)
    fi
    # Method 2: sysfs device/infiniband match (works for PCI-backed interfaces)
    if [ -z "$netdev" ] || [ -z "$(ip -4 addr show "$netdev" 2>/dev/null | grep -oP 'inet \K[0-9.]+')" ]; then
      for iface in /sys/class/net/*; do
        [ -d "$iface" ] || continue
        local name
        name=$(basename "$iface")
        [[ "$name" == lo ]] && continue
        [[ "$name" == eth0 ]] && continue
        if [ -d "$iface/device/infiniband" ]; then
          local iface_rdma
          iface_rdma=$(ls "$iface/device/infiniband" 2>/dev/null | head -1)
          if [ "$iface_rdma" = "$rdma_dev" ]; then
            local iface_ip
            iface_ip=$(ip -4 addr show "$name" 2>/dev/null | grep -oP 'inet \K[0-9.]+' | head -1)
            if [ -n "$iface_ip" ]; then
              netdev="$name"
              ip="$iface_ip"
              break
            fi
          fi
        fi
      done
    fi
    # Method 3: GID-based matching (works for macvlan/virtual interfaces).
    # RoCEv2 GIDs encode IPv4 as ::ffff:<ip> in the last 4 bytes.
    # Extract IPs from GIDs on this RDMA device and match against pod interfaces.
    if [ -z "$netdev" ] || [ -z "$ip" ]; then
      local gid_ips=()
      for gf in "$rd/ports/1/gids"/*; do
        [ -f "$gf" ] || continue
        local gid_val
        gid_val=$(cat "$gf" 2>/dev/null) || continue
        [[ "$gid_val" == 0000:0000:0000:0000:0000:0000:0000:0000 ]] && continue
        [[ "$gid_val" == fe80* ]] && continue
        # IPv4-mapped GID: 0000:0000:0000:0000:0000:ffff:AABB:CCDD
        if [[ "$gid_val" =~ 0000:0000:0000:0000:0000:ffff: ]]; then
          local hex_ip="${gid_val##*ffff:}"
          local o1=$((16#${hex_ip:0:2}))
          local o2=$((16#${hex_ip:2:2}))
          local o3=$((16#${hex_ip:5:2}))
          local o4=$((16#${hex_ip:7:2}))
          gid_ips+=("$o1.$o2.$o3.$o4")
        fi
      done
      for gip in "${gid_ips[@]}"; do
        for iface in /sys/class/net/*; do
          [ -d "$iface" ] || continue
          local name
          name=$(basename "$iface")
          [[ "$name" == lo ]] && continue
          [[ "$name" == eth0 ]] && continue
          local iface_ip
          iface_ip=$(ip -4 addr show "$name" 2>/dev/null | grep -oP 'inet \K[0-9.]+' | head -1)
          if [ -n "$iface_ip" ] && [ "$iface_ip" = "$gip" ]; then
            netdev="$name"
            ip="$iface_ip"
            break 2
          fi
        done
      done
    fi

    if [ -n "$netdev" ] && [ -z "$ip" ]; then
      ip=$(ip -4 addr show "$netdev" 2>/dev/null | grep -oP 'inet \K[0-9.]+' | head -1)
    fi

    nic_names+=("$rdma_dev")
    nic_switches+=("$sw")
    nic_ifaces+=("${netdev:-}")
    nic_ips+=("${ip:-}")
  done

  # Match GPUs to NICs by shared PCIe switch
  echo "["
  local first_gpu=true

  for ((g=0; g<${#gpu_bdfs[@]}; g++)); do
    local gpu_sw="${gpu_switches[$g]}"
    local hca_list=""
    local first_hca=true

    for ((n=0; n<${#nic_names[@]}; n++)); do
      if [ "${nic_switches[$n]}" = "$gpu_sw" ]; then
        [ "$first_hca" = true ] && first_hca=false || hca_list+=","
        local iface_json="null"
        local ip_json="null"
        [ -n "${nic_ifaces[$n]}" ] && iface_json="\"${nic_ifaces[$n]}\""
        [ -n "${nic_ips[$n]}" ] && ip_json="\"${nic_ips[$n]}\""
        # Collect all GID IPs for this RDMA device (shows multi-pod impact)
        local gid_list=""
        local first_gid=true
        for gf in /sys/class/infiniband/"${nic_names[$n]}"/ports/1/gids/*; do
          [ -f "$gf" ] || continue
          local gv
          gv=$(cat "$gf" 2>/dev/null) || continue
          [[ "$gv" == 0000:0000:0000:0000:0000:0000:0000:0000 ]] && continue
          [[ "$gv" == fe80* ]] && continue
          if [[ "$gv" =~ 0000:0000:0000:0000:0000:ffff: ]]; then
            local hx="${gv##*ffff:}"
            local a1=$((16#${hx:0:2})) a2=$((16#${hx:2:2})) a3=$((16#${hx:5:2})) a4=$((16#${hx:7:2}))
            local gidx
            gidx=$(basename "$gf")
            [ "$first_gid" = true ] && first_gid=false || gid_list+=","
            gid_list+="{\"index\": $gidx, \"ip\": \"$a1.$a2.$a3.$a4\"}"
          fi
        done
        hca_list+="{\"hca\": \"${nic_names[$n]}\", \"interface\": $iface_json, \"ip\": $ip_json, \"gids\": [$gid_list]}"
      fi
    done

    [ "$first_gpu" = true ] && first_gpu=false || echo ","
    echo -n "    {\"gpu\": $g, \"closest_hcas\": [$hca_list]}"
  done
  echo ""
  echo "]"
}

# ============================================================================
# Main
# ============================================================================
HOSTNAME="${HOSTNAME:-$(cat /proc/sys/kernel/hostname 2>/dev/null || echo unknown)}"

if [ "$OUTPUT_FORMAT" = "--json" ]; then
  echo "{"
  echo "  \"hostname\": \"$HOSTNAME\","
  echo "  \"gpu_nic_topology\": $(build_gpu_hca_mapping | tr '\n' ' ')"
  echo "}"
else
  echo "============================================"
  echo "  GPU -> NIC Topology: $HOSTNAME"
  echo "============================================"
  echo ""
  echo "Legend: PIX = same PCIe switch (optimal for GPUDirect)"
  echo ""

  mapping=$(build_gpu_hca_mapping)

  for gpu_idx in $(seq 0 $(($(echo "$mapping" | grep -c '"gpu"') - 1))); do
    gpu_data=$(echo "$mapping" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for e in data:
    if e['gpu'] == $gpu_idx:
        print(json.dumps(e))
        break
" 2>/dev/null) || continue
    [ -z "$gpu_data" ] && continue

    echo "GPU $gpu_idx:"
    echo "$gpu_data" | python3 -c "
import json, sys
entry = json.load(sys.stdin)
for hca in entry.get('closest_hcas', []):
    iface = hca.get('interface') or '(no interface)'
    ip = hca.get('ip') or 'no IP'
    gids = hca.get('gids', [])
    gid_str = ', '.join(['gid%d=%s' % (g['index'], g['ip']) for g in gids])
    print('  └─ %s (%s) → %s' % (hca['hca'], iface, ip))
    if gids:
        print('     GIDs: [%s]' % gid_str)
if not entry.get('closest_hcas'):
    print('  └─ (no PIX NIC found)')
" 2>/dev/null
    echo ""
  done
fi
