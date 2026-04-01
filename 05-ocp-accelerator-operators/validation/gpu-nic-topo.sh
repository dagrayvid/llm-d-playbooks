#!/bin/bash
# ============================================================================
# gpu-nic-topo.sh - Map GPUs to their closest NICs (PIX = same PCIe switch)
# ============================================================================
# Usage: gpu-nic-topo.sh [--json]
#
# Run inside a privileged pod with hostNetwork and GPU access.
# Parses nvidia-smi topo -m to find PIX (same PCIe switch) relationships
# between GPUs and RDMA HCAs, then resolves the host netdev interface.
# ============================================================================

set -euo pipefail

OUTPUT_FORMAT="${1:-text}"

build_gpu_hca_mapping() {
    local topo_output
    topo_output=$(nvidia-smi topo -m 2>/dev/null) || { echo "[]"; return; }

    topo_output=$(echo "$topo_output" | sed 's/\x1b\[[0-9;]*m//g')

    local header
    header=$(echo "$topo_output" | head -1)

    declare -a col_names
    local col_idx=0
    while IFS= read -r -d $'\t' col || [ -n "$col" ]; do
        col_names[$col_idx]=$(echo "$col" | tr -d ' ')
        ((col_idx++))
    done <<< "$header"

    declare -A nic_to_mlx
    while read -r line; do
        if [[ "$line" =~ NIC([0-9]+):\ *(mlx5_[0-9]+) ]]; then
            nic_to_mlx[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]}
        fi
    done <<< "$topo_output"

    declare -A mlx_to_ip
    declare -A mlx_to_iface
    local is_ipvlan=false

    for iface in /sys/class/net/*; do
        [ -d "$iface" ] || continue
        name=$(basename "$iface")
        [[ "$name" == lo ]] && continue
        [[ "$name" == eth0 ]] && continue

        ip=$(ip -4 addr show "$name" 2>/dev/null | grep -oP 'inet \K[0-9.]+' | head -1)

        if [ -d "$iface/device/infiniband" ]; then
            mlx=$(ls "$iface/device/infiniband" 2>/dev/null | head -1)
            if [ -n "$mlx" ]; then
                [ -n "$ip" ] && mlx_to_ip[$mlx]=$ip
                mlx_to_iface[$mlx]=$name
            fi
        elif [[ "$name" == net* ]]; then
            is_ipvlan=true
        fi
    done

    echo "["
    local first_gpu=true

    for gpu_idx in $(seq 0 7); do
        local gpu_line
        gpu_line=$(echo "$topo_output" | grep -E "^GPU${gpu_idx}[[:space:]]" | head -1) || continue
        [ -z "$gpu_line" ] && continue

        declare -a row_vals
        local ridx=0
        while IFS= read -r -d $'\t' val || [ -n "$val" ]; do
            row_vals[$ridx]=$(echo "$val" | tr -d ' ')
            ((ridx++))
        done <<< "$gpu_line"

        local pix_hcas=""
        local pix_first=true

        for ((i=0; i<${#col_names[@]}; i++)); do
            local col_name="${col_names[$i]}"

            if [[ "$col_name" =~ ^NIC([0-9]+)$ ]]; then
                local nic_idx="${BASH_REMATCH[1]}"
                local val_idx=$((i))
                local rel="${row_vals[$val_idx]:-}"

                if [ "$rel" = "PIX" ]; then
                    local mlx="${nic_to_mlx[$nic_idx]:-mlx5_$nic_idx}"
                    local ip="${mlx_to_ip[$mlx]:-}"
                    local iface="${mlx_to_iface[$mlx]:-}"

                    [ "$pix_first" = true ] && pix_first=false || pix_hcas+=","
                    if [ -n "$ip" ]; then
                        pix_hcas+="{\"hca\": \"$mlx\", \"interface\": \"$iface\", \"ip\": \"$ip\"}"
                    elif [ -n "$iface" ]; then
                        pix_hcas+="{\"hca\": \"$mlx\", \"interface\": \"$iface\", \"ip\": null}"
                    else
                        pix_hcas+="{\"hca\": \"$mlx\", \"interface\": null, \"ip\": null}"
                    fi
                fi
            fi
        done

        [ "$first_gpu" = true ] && first_gpu=false || echo ","
        echo -n "    {\"gpu\": $gpu_idx, \"closest_hcas\": [$pix_hcas]}"

        unset row_vals
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

    has_mapping=$(echo "$mapping" | jq '[.[].closest_hcas[] | select(.interface != null)] | length')

    for gpu_idx in $(seq 0 7); do
        gpu_data=$(echo "$mapping" | jq -r ".[] | select(.gpu == $gpu_idx)")
        [ -z "$gpu_data" ] && continue

        hcas_with_ip=$(echo "$gpu_data" | jq -r '.closest_hcas[] | select(.ip != null) | "  └─ \(.hca) (\(.interface)) → \(.ip)"')
        hcas_no_ip=$(echo "$gpu_data" | jq -r '.closest_hcas[] | select(.ip == null and .interface != null) | "  └─ \(.hca) (\(.interface)) — no IP"')
        hcas_none=$(echo "$gpu_data" | jq -r '.closest_hcas[] | select(.interface == null) | .hca' | tr '\n' ',' | sed 's/,$//')

        echo "GPU $gpu_idx:"
        [ -n "$hcas_with_ip" ] && echo "$hcas_with_ip"
        [ -n "$hcas_no_ip" ] && echo "$hcas_no_ip"
        [ -n "$hcas_none" ] && echo "  └─ $hcas_none (no mapped interface)"
        echo ""
    done

    if [ "$has_mapping" = "0" ]; then
        echo "============================================"
        echo "  NOTE: ipvlan/macvlan detected"
        echo "============================================"
        echo "Interface-to-HCA mapping cannot be determined from inside the pod."
        echo "Use 'oc debug node/<node>' to check host interface mappings."
        echo ""
        echo "Available interfaces with IPs:"
        for iface in /sys/class/net/net*; do
            [ -d "$iface" ] || continue
            name=$(basename "$iface")
            ip=$(ip -4 addr show "$name" 2>/dev/null | grep -oP 'inet \K[0-9.]+' | head -1)
            [ -n "$ip" ] && echo "  $name → $ip"
        done
        echo ""
    fi
fi
