#!/bin/bash
# ============================================================================
# pod-rdma-macvlan-diag.sh — Run inside a macvlan+RDMA test pod
# ============================================================================
# Expected env vars (set by run-diag-macvlan.sh wrapper):
#   NET_STATUS  — pod's k8s.v1.cni.cncf.io/network-status annotation JSON
#   PCI_PF_MAP  — newline-separated "mlx5_X=0000:XX:00.0=ensYYf0np0" from host
#   PEER_IPS    — comma-separated peer pod IPs for ping test
# ============================================================================

set -uo pipefail

PEER_IPS="${1:-${PEER_IPS:-}}"

section() { echo ""; echo "========== $1 =========="; echo ""; }
debug()   { echo "  [DEBUG] $*"; }

# ---- 0. Raw data dumps for debugging ----
section "DEBUG: Raw Data Available Inside Pod"

debug "--- rdma link show ---"
rdma link show 2>&1 | sed 's/^/  /'
echo ""

debug "--- /sys/class/infiniband/*/device/net/ contents ---"
for rd in /sys/class/infiniband/mlx5_*; do
    [ -d "$rd" ] || continue
    hca=$(basename "$rd")
    netdir="$rd/device/net"
    if [ -d "$netdir" ]; then
        nets=$(ls "$netdir" 2>/dev/null | tr '\n' ' ')
        debug "  $hca → device/net/ = [${nets}]"
    else
        debug "  $hca → device/net/ DOES NOT EXIST"
    fi
done
echo ""

debug "--- PCI_PF_MAP from host (via wrapper) ---"
if [ -n "${PCI_PF_MAP:-}" ]; then
    echo "${PCI_PF_MAP}" | sed 's/^/  /'
else
    debug "  (not set — run via run-diag-macvlan.sh wrapper)"
fi
echo ""

debug "--- NET_STATUS env var (first 500 chars) ---"
echo "  ${NET_STATUS:0:500}"
echo ""

debug "--- ip -o link show (all interfaces) ---"
ip -o link show 2>&1 | sed 's/^/  /'

# ---- 1. Macvlan interfaces and IPs ----
section "Macvlan Interfaces"

declare -A IFACE_IP

for name in $(ip -o link show | grep -oP 'net\d+' | sort -V); do
    ip_addr=$(ip -4 addr show "$name" 2>/dev/null | grep -oP 'inet \K[0-9./]+' | head -1)
    mac=$(ip link show "$name" 2>/dev/null | grep -oP 'link/ether \K[^ ]+')
    printf "  %-6s  IP=%-18s  MAC=%s\n" "$name" "${ip_addr:-none}" "${mac:-?}"
    [ -n "$ip_addr" ] && IFACE_IP[$name]="$ip_addr"
done

# ---- 2. Parse network-status annotation → net* to PF mapping ----
section "Network Status → PF Mapping"

declare -A NET_TO_PF
declare -A PF_TO_NET

if [ -n "${NET_STATUS:-}" ]; then
    python3 -c "
import json, sys, os
try:
    data = json.loads(os.environ['NET_STATUS'])
    for entry in data:
        iface = entry.get('interface', '')
        name = entry.get('name', '')
        ips = entry.get('ips', [])
        if not iface.startswith('net'):
            continue
        nad = name.split('/')[-1] if '/' in name else name
        ip_str = ','.join(ips)
        if '-macvlan' in name and 'roce-net-' not in name:
            pf = nad.replace('-macvlan', '')
            print(f'NET_TO_PF[{iface}]={pf}')
            print(f'PF_TO_NET[{pf}]={iface}')
            print(f'# {iface:<6}  NAD={nad:<24}  PF={pf:<14}  IPs={ip_str}')
        elif 'roce-net-' in name:
            print(f'# {iface:<6}  NAD={nad:<24}  PF=(macvlan parent)  IPs={ip_str}')
except Exception as e:
    print(f'# ERROR: {e}', file=sys.stderr)
" > /tmp/_pf_eval.sh 2>&1

    while IFS= read -r line; do
        if [[ "$line" == \#* ]]; then
            echo " ${line#\# }"
        fi
    done < /tmp/_pf_eval.sh
    source /tmp/_pf_eval.sh 2>/dev/null || debug "source failed"

    # Abstract NAD names (roce-net-*): map net* -> kernel PF via macvlan parent (ip -d link)
    while read -r iface; do
        [[ "$iface" =~ ^net[0-9]+$ ]] || continue
        if [[ -n "${NET_TO_PF[$iface]:-}" ]] && [[ "${NET_TO_PF[$iface]}" =~ ^ens ]]; then
            continue
        fi
        pf=$(ip -d link show "$iface" 2>/dev/null | grep -oE 'ens[0-9a-z]+f[0-9]+np[0-9]+' | head -1)
        if [[ -n "$pf" ]]; then
            NET_TO_PF[$iface]=$pf
            PF_TO_NET[$pf]=$iface
        fi
    done < <(ip -o link show | awk -F': ' '$2 ~ /^net[0-9]+(@|$)/ {gsub(/@.*/,"",$2); print $2}')
else
    echo "  NET_STATUS not set. Use run-diag-macvlan.sh wrapper."
fi

debug "NET_TO_PF entries: ${#NET_TO_PF[@]}"
debug "PF_TO_NET entries: ${#PF_TO_NET[@]}"

# ---- 3. Build HCA → PCI map and parse PCI_PF_MAP from host ----
section "RDMA Devices + Host PCI→PF Mapping"

declare -A HCA_PCI
declare -A HCA_TO_PF
declare -A PCI_TO_PF_HOST

if [ -n "${PCI_PF_MAP:-}" ]; then
    debug "Parsing PCI_PF_MAP from host..."
    while IFS='=' read -r hca pci pf; do
        [ -z "$hca" ] && continue
        PCI_TO_PF_HOST[$pci]="$pf"
        HCA_TO_PF[$hca]="$pf"
        debug "  HOST: $hca → PCI=$pci → PF=$pf"
    done <<< "$PCI_PF_MAP"
else
    debug "PCI_PF_MAP not set — cannot map HCA→PF"
fi

echo ""
debug "Enumerating RDMA devices from pod sysfs..."

for rd in /sys/class/infiniband/mlx5_*; do
    [ -d "$rd" ] || continue
    hca=$(basename "$rd")
    pci=$(basename "$(readlink -f "$rd/device" 2>/dev/null)") 2>/dev/null || pci="?"
    state=$(cat "$rd/ports/1/state" 2>/dev/null | awk '{print $2}') || state="?"
    phys=$(cat "$rd/ports/1/phys_state" 2>/dev/null | awk '{print $2}') || phys="?"
    HCA_PCI[$hca]="$pci"

    if [ -z "${HCA_TO_PF[$hca]:-}" ] && [ -n "${PCI_TO_PF_HOST[$pci]:-}" ]; then
        HCA_TO_PF[$hca]="${PCI_TO_PF_HOST[$pci]}"
    fi

    pf_resolved="${HCA_TO_PF[$hca]:-?}"
    printf "  %-8s  PCI=%-14s  state=%-8s  phys=%-8s  PF=%s\n" \
        "$hca" "$pci" "$state" "$phys" "$pf_resolved"
done

echo ""
debug "HCA_TO_PF final map (${#HCA_TO_PF[@]} entries):"
for k in $(echo "${!HCA_TO_PF[@]}" | tr ' ' '\n' | sort -V); do
    debug "  $k → ${HCA_TO_PF[$k]}"
done

# ---- 4. GPU → HCA topology ----
section "GPU → HCA Topology (nvidia-smi topo -m)"

TOPO=$(nvidia-smi topo -m 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g') || TOPO=""

declare -A GPU_BEST_HCA
declare -A GPU_ALL_HCAS

if [ -z "$TOPO" ]; then
    echo "  nvidia-smi topo not available"
else
    HEADER=$(echo "$TOPO" | head -1)

    declare -a COL_NAMES=()
    cidx=0
    while IFS= read -r -d $'\t' col || [ -n "$col" ]; do
        COL_NAMES[$cidx]=$(echo "$col" | tr -d ' ')
        ((cidx++))
    done <<< "$HEADER"

    declare -A NIC_TO_MLX
    while read -r line; do
        if [[ "$line" =~ NIC([0-9]+):\ *(mlx5_[0-9]+) ]]; then
            NIC_TO_MLX[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]}
        fi
    done <<< "$TOPO"

    for gpu in $(seq 0 15); do
        gpu_line=$(echo "$TOPO" | grep -E "^GPU${gpu}[[:space:]]" | head -1) || continue
        [ -z "$gpu_line" ] && continue

        declare -a VALS=()
        vidx=0
        while IFS= read -r -d $'\t' val || [ -n "$val" ]; do
            VALS[$vidx]=$(echo "$val" | tr -d ' ')
            ((vidx++))
        done <<< "$gpu_line"

        best_hca=""
        all_nics=""

        for ((i=0; i<${#COL_NAMES[@]}; i++)); do
            cn="${COL_NAMES[$i]}"
            if [[ "$cn" =~ ^NIC([0-9]+)$ ]]; then
                nidx="${BASH_REMATCH[1]}"
                rel="${VALS[$i]:-}"
                if [ "$rel" = "PIX" ] || [ "$rel" = "PXB" ] || [ "$rel" = "PHB" ]; then
                    mlx="${NIC_TO_MLX[$nidx]:-mlx5_$nidx}"
                    [ -n "$all_nics" ] && all_nics+=", "
                    all_nics+="$mlx[$rel]"
                    if [ -z "$best_hca" ] || [ "$rel" = "PIX" ]; then
                        best_hca="$mlx"
                    fi
                fi
            fi
        done

        GPU_BEST_HCA[$gpu]="${best_hca:-}"
        GPU_ALL_HCAS[$gpu]="${all_nics:-}"
        printf "  GPU %-2d → %s\n" "$gpu" "${all_nics:-no close NICs found}"
        unset VALS
    done
fi

# ---- 5. Combined mapping table ----
section "Combined Mapping: GPU → HCA → PF → Macvlan → IP"

printf "  %-6s  %-8s  %-14s  %-6s  %-18s  %s\n" "GPU" "HCA" "PF" "iface" "IP" "Relation"
printf "  %-6s  %-8s  %-14s  %-6s  %-18s  %s\n" "------" "--------" "--------------" "------" "------------------" "--------"

for gpu in $(seq 0 15); do
    all="${GPU_ALL_HCAS[$gpu]:-}"
    [ -z "$all" ] && continue

    for entry in $(echo "$all" | tr ',' '\n' | tr -d ' '); do
        hca=$(echo "$entry" | grep -oP 'mlx5_\d+')
        rel=$(echo "$entry" | grep -oP '\[\K[^\]]+')

        pf="${HCA_TO_PF[$hca]:-?}"
        net="${PF_TO_NET[$pf]:-}"
        ip=""
        if [ -n "$net" ]; then
            ip="${IFACE_IP[$net]:-?}"
        else
            net="--"
            ip="--"
        fi

        printf "  %-6s  %-8s  %-14s  %-6s  %-18s  %s\n" \
            "GPU $gpu" "$hca" "$pf" "$net" "$ip" "$rel"
    done
done

# ---- 6. Full NIC inventory ----
section "Full NIC Inventory"

printf "  %-8s  %-14s  %-14s  %-6s  %-18s\n" "HCA" "PCI" "PF" "iface" "IP"
printf "  %-8s  %-14s  %-14s  %-6s  %-18s\n" "--------" "--------------" "--------------" "------" "------------------"

for hca in $(echo "${!HCA_PCI[@]}" | tr ' ' '\n' | sort -V); do
    pci="${HCA_PCI[$hca]}"
    pf="${HCA_TO_PF[$hca]:-?}"
    net=""
    ip="--"
    if [ "$pf" != "?" ]; then
        net="${PF_TO_NET[$pf]:-}"
        if [ -n "$net" ]; then
            ip="${IFACE_IP[$net]:-?}"
        fi
    fi
    [ -z "$net" ] && net="--"
    printf "  %-8s  %-14s  %-14s  %-6s  %-18s\n" "$hca" "$pci" "$pf" "$net" "$ip"
done

# ---- 7. Ping mesh test ----
if [ -n "$PEER_IPS" ]; then
    section "Ping Mesh Test"

    IFS=',' read -ra PEERS <<< "$PEER_IPS"
    ok=0
    fail=0
    for peer_ip in "${PEERS[@]}"; do
        peer_ip=$(echo "$peer_ip" | tr -d ' ')
        if ping -c1 -W2 "$peer_ip" &>/dev/null; then
            printf "  %-18s  OK\n" "$peer_ip"
            ((ok++))
        else
            printf "  %-18s  FAIL\n" "$peer_ip"
            ((fail++))
        fi
    done
    echo ""
    echo "  Results: $ok reachable, $fail unreachable out of ${#PEERS[@]}"
else
    section "Ping Test (skipped — pass peer IPs as argument)"
    echo "  Get peer pod IPs:"
    echo "    oc exec rdma-macvlan-test-1 -n llm-d-setup -- \\"
    echo "      ip -4 -o addr show | grep 'net[0-9]' | awk '{print \$4}' | cut -d/ -f1 | paste -sd,"
fi

echo ""
echo "Done."
