#!/bin/bash
# Automated installation of OCP accelerator operators.
#
# Usage:
#   ./install.sh --case-study <ibm-cloud-vpc|bare-metal-dell-b200-bf3>
#
# Each case study has its own ordered set of steps. This script applies
# them sequentially, waiting for readiness between steps.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "Usage: $0 --case-study <ibm-cloud-vpc|bare-metal-dell-b200-bf3>"
  echo ""
  echo "Case studies:"
  echo "  ibm-cloud-vpc                IBM Cloud VPC bare-metal workers (host-device CNI)"
  echo "  bare-metal-dell-b200-bf3     Dell MX750c, B200 GPUs, BlueField-3 (macvlan + RoCE)"
  exit 1
}

CASE_STUDY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --case-study) CASE_STUDY="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

if [ -z "$CASE_STUDY" ]; then
  echo "ERROR: --case-study is required"
  usage
fi

case "$CASE_STUDY" in
  ibm-cloud-vpc|bare-metal-dell-b200-bf3) ;;
  *) echo "ERROR: Unknown case study '$CASE_STUDY'"; usage ;;
esac

CASE_DIR="$SCRIPT_DIR/$CASE_STUDY"

echo "=========================================="
echo "OCP Accelerator Operators Installation"
echo "Case study: $CASE_STUDY"
echo "=========================================="
echo ""

apply_step() {
  local step_name="$1"
  local step_path="$2"
  echo "--- Step: $step_name ---"
  echo "  Applying: $step_path"
  oc apply -k "$step_path"
  echo "  Done."
  echo ""
}

wait_for_csv() {
  local namespace="$1"
  local name_pattern="$2"
  local timeout="${3:-600}"

  echo "  Waiting for CSV matching '$name_pattern' in $namespace..."
  local elapsed=0
  while [ $elapsed -lt $timeout ]; do
    local csv_phase
    csv_phase=$(oc get csv -n "$namespace" -o jsonpath="{.items[?(@.metadata.name=='$name_pattern')].status.phase}" 2>/dev/null || echo "")
    if [ -z "$csv_phase" ]; then
      csv_phase=$(oc get csv -n "$namespace" -o json 2>/dev/null | python3 -c "
import json,sys
data=json.load(sys.stdin)
for item in data.get('items',[]):
    if '$name_pattern' in item['metadata']['name']:
        print(item.get('status',{}).get('phase',''))
        break
" 2>/dev/null || echo "")
    fi
    if [ "$csv_phase" = "Succeeded" ]; then
      echo "  CSV ready."
      return 0
    fi
    sleep 10
    elapsed=$((elapsed + 10))
  done
  echo "  WARNING: CSV not ready after ${timeout}s, continuing..."
}

wait_for_subscription() {
  local namespace="$1"
  local name="$2"
  local timeout="${3:-300}"

  echo "  Waiting for subscription '$name' in $namespace..."
  local elapsed=0
  while [ $elapsed -lt $timeout ]; do
    local state
    state=$(oc get subscription.operators.coreos.com "$name" -n "$namespace" -o jsonpath='{.status.state}' 2>/dev/null || echo "")
    if [ "$state" = "AtLatestKnown" ]; then
      echo "  Subscription ready."
      return 0
    fi
    sleep 10
    elapsed=$((elapsed + 10))
  done
  echo "  WARNING: Subscription not ready after ${timeout}s, continuing..."
}

# =========================================================================
# Common steps (shared across case studies)
# =========================================================================

# Step 00: Discover GPUs & NICs (informational)
echo "--- Step: 00-discover-gpus-nics ---"
echo "  Running hardware probe..."
bash "$SCRIPT_DIR/common/00-discover-gpus-nics/discover-gpu-nic-topology.sh" || true
echo ""

# Step 01: Install NFD, GPU, and Network Operator subscriptions
apply_step "01-operator-subscriptions" "$CASE_DIR/01-operator-subscriptions"

echo "Waiting for operator subscriptions to install..."
wait_for_subscription "openshift-nfd" "nfd" 300
wait_for_subscription "nvidia-gpu-operator" "gpu-operator-certified" 300
wait_for_subscription "nvidia-network-operator" "nvidia-network-operator" 300

# Step 02: Deploy NFD operands
apply_step "02-nfd-operands" "$CASE_DIR/02-nfd-operands"

# =========================================================================
# Case-study-specific steps
# =========================================================================

if [ "$CASE_STUDY" = "bare-metal-dell-b200-bf3" ]; then

  # Step 03: Worker node GPU/RDMA config (iommu=pt, ACS disable, memlock)
  apply_step "03-worker-gpu-rdma-config" "$CASE_DIR/03-worker-gpu-rdma-config/base"
  echo "  Waiting for MachineConfigPool to update (nodes will reboot)..."
  oc wait mcp worker --for=condition=Updated --timeout=1800s 2>/dev/null || echo "  MCP wait timed out or not applicable"
  echo ""

  # Step 10: SR-IOV operator
  apply_step "10-sriov-operator" "$CASE_DIR/10-sriov-operator"
  wait_for_subscription "openshift-sriov-network-operator" "sriov-network-operator-subscription" 300

  # Step 11: IB interface normalization (optional)
  apply_step "11-ib-interface-normalization" "$CASE_DIR/11-ib-interface-normalization"
  echo "  Waiting for MachineConfigPool to update (nodes may reboot)..."
  oc wait mcp worker --for=condition=Updated --timeout=1800s 2>/dev/null || echo "  MCP wait timed out or not applicable"
  echo ""

  # Step 12: NIC discovery
  apply_step "12-nic-discovery" "$CASE_DIR/12-nic-discovery"
  echo "  Waiting for discovery DaemonSet to complete..."
  sleep 60

  # Step 13: SR-IOV VF config
  apply_step "13-sriov-vf-config" "$CASE_DIR/13-sriov-vf-config"

  # Step 14: NVIDIA network operator config
  apply_step "14-nvidia-network-operator" "$CASE_DIR/14-nvidia-network-operator"

  # Step 15: RoCE macvlan + SBR
  apply_step "15-roce-macvlan" "$CASE_DIR/15-roce-macvlan/base"
  echo "  Waiting for macvlan configuration job to complete..."
  oc wait --for=condition=complete job/configure-macvlan-networks -n nvidia-network-operator --timeout=300s 2>/dev/null || true
  echo ""

elif [ "$CASE_STUDY" = "ibm-cloud-vpc" ]; then

  # Step 14: NVIDIA network operator config (IBM Cloud — MOFED only)
  apply_step "14-nvidia-network-operator" "$CASE_DIR/14-nvidia-network-operator"

  # Step 15: IBM Cloud networking (IOMMU MachineConfig + SBR + NADs)
  apply_step "15-networking" "$CASE_DIR/15-networking"
  echo "  Waiting for MachineConfigPool to update (nodes may reboot)..."
  oc wait mcp gpu-h100 --for=condition=Updated --timeout=1800s 2>/dev/null || echo "  MCP wait timed out or not applicable"
  echo ""

fi

# =========================================================================
# Common steps (post-networking)
# =========================================================================

# Step 20: Wait for operator readiness
apply_step "20-gpu-readiness" "$CASE_DIR/20-gpu-readiness"
echo "  Waiting for readiness jobs to complete..."
oc wait --for=condition=complete job/wait-for-network-operator-ready -n llm-d-setup --timeout=1800s 2>/dev/null || true
oc wait --for=condition=complete job/wait-for-mofed-ready -n llm-d-setup --timeout=1800s 2>/dev/null || true

# Step 21: Deploy GPU operands
apply_step "21-gpu-operands" "$CASE_DIR/21-gpu-operands"

echo "=========================================="
echo "Installation Complete"
echo "=========================================="
echo ""
echo "Verify GPU operator status:"
echo "  oc get clusterpolicy"
echo "  oc get pods -n nvidia-gpu-operator"
echo ""
echo "Verify network operator status:"
echo "  oc get nicclusterpolicy"
echo "  oc get pods -n nvidia-network-operator"
if [ "$CASE_STUDY" = "bare-metal-dell-b200-bf3" ]; then
  echo ""
  echo "Verify RoCE macvlan NADs:"
  echo "  oc get net-attach-def -n openshift-multus"
fi
if [ "$CASE_STUDY" = "ibm-cloud-vpc" ]; then
  echo ""
  echo "Verify IBM Cloud networking:"
  echo "  oc get mcp gpu-h100"
  echo "  oc get ds cni-sbr-custom-plugin -n openshift-multus"
  echo "  oc get net-attach-def"
fi
