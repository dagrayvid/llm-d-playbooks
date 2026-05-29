#!/bin/bash
# Capture eswitch/VF configuration on a node while in the broken state.
# Usage: bash capture-eswitch-state.sh <node-fqdn>
# Run this AFTER pair B is deployed and RDMA is broken.

NODE="${1:?Usage: $0 <node-fqdn>}"
NODE_SHORT="${NODE%%.*}"
OUTDIR="eswitch-state-${NODE_SHORT}"
mkdir -p "$OUTDIR"

PFS=(ens40f0np0 ens41f0np0 ens38f0np0 ens37f0np0 ens32f0np0 ens31f0np0 ens36f0np0 ens35f0np0)
PCIS=(0000:18:00.0 0000:3a:00.0 0000:4d:00.0 0000:5d:00.0 0000:9b:00.0 0000:ba:00.0 0000:ca:00.0 0000:db:00.0)

echo "=== Capturing eswitch state on ${NODE_SHORT} ==="

echo ""
echo "--- VF configuration (ip link show) ---"
for pf in "${PFS[@]}"; do
  echo "  ${pf}..."
  oc debug "node/${NODE}" --quiet -- chroot /host \
    ip link show "$pf" > "${OUTDIR}/ip-link-${pf}.txt" 2>&1
done

echo ""
echo "--- Eswitch mode (devlink) ---"
oc debug "node/${NODE}" --quiet -- chroot /host \
  bash -c 'for pci in 0000:18:00.0 0000:3a:00.0 0000:4d:00.0 0000:5d:00.0 0000:9b:00.0 0000:ba:00.0 0000:ca:00.0 0000:db:00.0; do echo -n "$pci: "; devlink dev eswitch show pci/$pci 2>&1; done' \
  > "${OUTDIR}/devlink-eswitch.txt" 2>&1

echo ""
echo "--- sriov_numvfs per PF ---"
oc debug "node/${NODE}" --quiet -- chroot /host \
  bash -c 'for pf in ens40f0np0 ens41f0np0 ens38f0np0 ens37f0np0 ens32f0np0 ens31f0np0 ens36f0np0 ens35f0np0; do echo -n "$pf: "; cat /sys/class/net/$pf/device/sriov_numvfs; done' \
  > "${OUTDIR}/sriov-numvfs.txt" 2>&1

echo ""
echo "--- Bridge FDB for PFs (if switchdev) ---"
oc debug "node/${NODE}" --quiet -- chroot /host \
  bash -c 'bridge fdb show 2>/dev/null | grep -E "ens4[012]f0|ens3[1-8]f0" | head -100' \
  > "${OUTDIR}/bridge-fdb.txt" 2>&1

echo ""
echo "=== Done: ${OUTDIR}/ ==="
echo ""
echo "Key things to look for in ip-link-*.txt:"
echo "  - VF MAC addresses (should be unique per VF)"
echo "  - VF link-state (should be 'auto' or 'enable')"
echo "  - VF spoofchk (on/off)"
echo "  - VF trust (on/off)"
echo "  - VF VLAN (should be 0 for untagged)"
cat "${OUTDIR}/ip-link-${PFS[0]}.txt"
