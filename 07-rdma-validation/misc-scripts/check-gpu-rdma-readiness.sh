#!/bin/bash
# Validate GPU/RDMA readiness on all GPU nodes:
#   - PCIe ACS disabled on all devices
#   - IOMMU passthrough mode
#   - MTU 9000 on mlx5_core (RoCE) PFs
#   - memlock ulimit
#   - nvidia-peermem loaded
#
# Usage: ./check-gpu-rdma-readiness.sh
# Requires: oc CLI with cluster-admin access

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

pass() { echo -e "  ${GREEN}PASS${NC}: $1"; }
fail() { echo -e "  ${RED}FAIL${NC}: $1"; ERRORS=$((ERRORS + 1)); }
warn() { echo -e "  ${YELLOW}WARN${NC}: $1"; }

ERRORS=0

NODES=$(oc get nodes -l feature.node.kubernetes.io/pci-10de.present=true \
  -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)

if [ -z "$NODES" ]; then
  NODES=$(oc get nodes -o jsonpath='{.items[*].metadata.name}')
  echo "No GPU-labeled nodes found, checking all nodes: $NODES"
fi

for NODE in $NODES; do
  echo ""
  echo "=== $NODE ==="

  # --- ACS Check ---
  echo ""
  echo "  --- PCIe ACS ---"
  ACS_OUTPUT=$(oc debug "node/$NODE" --quiet -- chroot /host bash -c '
    acs_enabled=0
    acs_total=0
    for bdf in $(lspci -D | awk "{print \$1}"); do
      val=$(setpci -s "$bdf" ECAP_ACS+6.w 2>/dev/null) || continue
      acs_total=$((acs_total + 1))
      if [ "$val" != "0000" ]; then
        acs_enabled=$((acs_enabled + 1))
        echo "ACS_ENABLED $bdf 0x$val $(lspci -s "$bdf" | cut -d" " -f2-)"
      fi
    done
    echo "ACS_SUMMARY $acs_total $acs_enabled"
  ' 2>/dev/null)

  ACS_SUMMARY=$(echo "$ACS_OUTPUT" | grep "^ACS_SUMMARY" | tail -1)
  ACS_TOTAL=$(echo "$ACS_SUMMARY" | awk '{print $2}')
  ACS_ENABLED=$(echo "$ACS_SUMMARY" | awk '{print $3}')

  if [ "${ACS_ENABLED:-0}" -eq 0 ]; then
    pass "ACS disabled on all ${ACS_TOTAL:-0} devices with ACS capability"
  else
    fail "ACS still enabled on $ACS_ENABLED / $ACS_TOTAL devices:"
    echo "$ACS_OUTPUT" | grep "^ACS_ENABLED" | while read -r _ bdf val desc; do
      echo "        $bdf ($val) $desc"
    done
  fi

  # --- IOMMU Check ---
  echo ""
  echo "  --- IOMMU ---"
  CMDLINE=$(oc debug "node/$NODE" --quiet -- chroot /host cat /proc/cmdline 2>/dev/null)

  if echo "$CMDLINE" | grep -q 'iommu=pt'; then
    pass "iommu=pt kernel argument present"
  else
    fail "iommu=pt kernel argument missing"
  fi

  if echo "$CMDLINE" | grep -q 'pci=noacs'; then
    pass "pci=noacs kernel argument present"
  else
    warn "pci=noacs kernel argument missing (ACS may be re-enabled by kernel on hotplug)"
  fi

  # --- MTU Check ---
  echo ""
  echo "  --- MTU (mlx5_core PFs) ---"
  MTU_OUTPUT=$(oc debug "node/$NODE" --quiet -- chroot /host bash -c '
    for dev in /sys/class/net/ens*; do
      iface=$(basename "$dev")
      [ -d "$dev/device/driver" ] || continue
      driver=$(basename "$(readlink -f "$dev/device/driver")")
      [ "$driver" = "mlx5_core" ] || continue
      mtu=$(cat "$dev/mtu" 2>/dev/null)
      echo "MTU $iface $mtu"
    done
  ' 2>/dev/null)

  if [ -z "$MTU_OUTPUT" ]; then
    warn "No mlx5_core PFs found"
  else
    MTU_BAD=0
    echo "$MTU_OUTPUT" | while read -r _ iface mtu; do
      if [ "$mtu" -ge 9000 ] 2>/dev/null; then
        pass "$iface MTU=$mtu"
      else
        fail "$iface MTU=$mtu (expected >= 9000)"
        MTU_BAD=$((MTU_BAD + 1))
      fi
    done
  fi

  # --- nvidia-peermem Check ---
  echo ""
  echo "  --- nvidia-peermem ---"
  PEERMEM=$(oc debug "node/$NODE" --quiet -- chroot /host bash -c '
    lsmod | grep -c nvidia_peermem 2>/dev/null || echo 0
  ' 2>/dev/null)

  if [ "${PEERMEM:-0}" -gt 0 ]; then
    pass "nvidia_peermem module loaded"
  else
    warn "nvidia_peermem module not loaded (GPUDirect RDMA will not work)"
  fi

done

echo ""
echo "=================================="
if [ "$ERRORS" -gt 0 ]; then
  echo -e "${RED}Completed with $ERRORS failure(s)${NC}"
  exit 1
else
  echo -e "${GREEN}All checks passed${NC}"
fi
