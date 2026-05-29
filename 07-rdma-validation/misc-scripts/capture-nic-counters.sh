#!/bin/bash
# Capture ethtool -S counters on all 8 RoCE PFs for a given node.
# Usage: bash capture-nic-counters.sh <node-name> <label>
# Example: bash capture-nic-counters.sh dell-b200-1.bmas-001.lab.rdu2.dc.redhat.com before
#
# Outputs: nic-counters-<label>/<node-short>-<pf>.txt

NODE="${1:?Usage: $0 <node-fqdn> <label>}"
LABEL="${2:?Usage: $0 <node-fqdn> <label>}"

NODE_SHORT="${NODE%%.*}"
OUTDIR="nic-counters-${LABEL}"
mkdir -p "$OUTDIR"

PFS=(ens40f0np0 ens41f0np0 ens38f0np0 ens37f0np0 ens32f0np0 ens31f0np0 ens36f0np0 ens35f0np0)

echo "=== Capturing ethtool -S on ${NODE_SHORT} (${#PFS[@]} PFs) → ${OUTDIR}/ ==="

for pf in "${PFS[@]}"; do
  echo -n "  ${pf}..."
  oc debug "node/${NODE}" --quiet -- chroot /host \
    ethtool -S "$pf" > "${OUTDIR}/${NODE_SHORT}-${pf}.txt" 2>&1
  echo " done ($(wc -l < "${OUTDIR}/${NODE_SHORT}-${pf}.txt") lines)"
done

echo ""
echo "=== Capture complete: ${OUTDIR}/ ==="
echo "To diff: diff nic-counters-before/<file> nic-counters-after/<file>"
