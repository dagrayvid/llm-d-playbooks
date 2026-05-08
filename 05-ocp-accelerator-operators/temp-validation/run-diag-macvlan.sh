#!/bin/bash
# ============================================================================
# run-diag-macvlan.sh — Wrapper to run pod-rdma-macvlan-diag.sh on test pods
# ============================================================================
# Usage:
#   ./run-diag-macvlan.sh [pod-name] [namespace]
#
# Defaults:
#   pod-name:  rdma-macvlan-test-0
#   namespace: llm-d-setup
#
# What it does:
#   1. Fetches the pod's network-status annotation (net* → NAD → PF mapping)
#   2. Gets HCA PCI→PF name mapping from the host (via MOFED driver pod)
#   3. Copies the diag script into the pod and runs it
#   4. Optionally runs a cross-pod ping mesh test
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIAG_SCRIPT="$SCRIPT_DIR/pod-rdma-macvlan-diag.sh"
POD="${1:-rdma-macvlan-test-0}"
NS="${2:-llm-d-setup}"

if [ ! -f "$DIAG_SCRIPT" ]; then
    echo "ERROR: pod-rdma-macvlan-diag.sh not found at $DIAG_SCRIPT"
    exit 1
fi

echo "==> Target: $POD in namespace $NS"

# ---- 1. Fetch network-status annotation ----
echo "==> Fetching network-status annotation..."
NET_STATUS=$(oc get pod "$POD" -n "$NS" \
    -o jsonpath='{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/network-status}' 2>/dev/null || echo "")

if [ -z "$NET_STATUS" ]; then
    echo "WARNING: Could not fetch network-status annotation for $POD."
fi

# ---- 2. Get HCA PCI→PF mapping from the host ----
echo "==> Getting HCA→PCI→PF mapping from the host..."

NODE=$(oc get pod "$POD" -n "$NS" -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "")
PCI_PF_MAP=""

if [ -n "$NODE" ]; then
    echo "    Pod is on node: $NODE"

    # Try MOFED driver pod first (faster than oc debug, already running)
    MOFED_NS="nvidia-network-operator"
    MOFED_POD=$(oc get pods -n "$MOFED_NS" -o name --field-selector "spec.nodeName=$NODE" 2>/dev/null \
        | grep -i mofed | head -1 | sed 's|^pod/||' || echo "")

    if [ -n "$MOFED_POD" ]; then
        echo "    Using MOFED pod: $MOFED_POD in $MOFED_NS"
        PCI_PF_MAP=$(oc exec "$MOFED_POD" -n "$MOFED_NS" -c mofed-container -- \
            bash -c 'for d in /sys/class/infiniband/mlx5_*; do
                [ -d "$d" ] || continue
                hca=$(basename "$d")
                pci=$(basename "$(readlink -f "$d/device")" 2>/dev/null)
                pf=$(ls "$d/device/net/" 2>/dev/null | head -1)
                [ -n "$pf" ] && echo "${hca}=${pci}=${pf}"
            done' 2>/dev/null || echo "")
    fi

    # Fallback: oc debug node
    if [ -z "$PCI_PF_MAP" ]; then
        echo "    MOFED pod not found, trying oc debug node/$NODE..."
        PCI_PF_MAP=$(oc debug "node/$NODE" -- chroot /host bash -c '
            for d in /sys/class/infiniband/mlx5_*; do
                [ -d "$d" ] || continue
                hca=$(basename "$d")
                pci=$(basename "$(readlink -f "$d/device")" 2>/dev/null)
                pf=$(ls "$d/device/net/" 2>/dev/null | head -1)
                [ -n "$pf" ] && echo "${hca}=${pci}=${pf}"
            done' 2>/dev/null || echo "")
    fi

    if [ -n "$PCI_PF_MAP" ]; then
        echo "    Got PCI→PF map:"
        echo "$PCI_PF_MAP" | sed 's/^/      /'
    else
        echo "    WARNING: Could not get PCI→PF mapping from host."
    fi
else
    echo "    WARNING: Could not determine node for $POD."
fi

# ---- 3. Copy script into the pod ----
echo "==> Copying diag script into pod..."
oc cp "$DIAG_SCRIPT" "$NS/$POD:/tmp/diag.sh"

# ---- 4. Determine peer IPs ----
PEER_IPS=""
PEER_POD=""
if [[ "$POD" == *-0 ]]; then
    PEER_POD="${POD%-0}-1"
elif [[ "$POD" == *-1 ]]; then
    PEER_POD="${POD%-1}-0"
fi

if [ -n "$PEER_POD" ]; then
    echo "==> Getting peer IPs from $PEER_POD..."
    PEER_IPS=$(oc exec "$PEER_POD" -n "$NS" -- \
        ip -4 -o addr show 2>/dev/null \
        | grep 'net[0-9]' \
        | awk '{print $4}' \
        | cut -d/ -f1 \
        | paste -sd, 2>/dev/null || echo "")

    if [ -n "$PEER_IPS" ]; then
        echo "    Peer IPs: $PEER_IPS"
    else
        echo "    Could not get peer IPs from $PEER_POD (pod may not exist)"
    fi
fi

# ---- 5. Run the diagnostic script ----
echo "==> Running diagnostic script in $POD..."
echo ""

oc exec "$POD" -n "$NS" -- env \
    NET_STATUS="$NET_STATUS" \
    PCI_PF_MAP="$PCI_PF_MAP" \
    PEER_IPS="$PEER_IPS" \
    bash /tmp/diag.sh
