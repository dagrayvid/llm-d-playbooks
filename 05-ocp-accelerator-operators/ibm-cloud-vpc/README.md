# Case Study: IBM Cloud VPC Bare-Metal Workers

## Environment

- **Platform**: IBM Cloud VPC bare-metal workers (`gx3d-160x1792x8h100` or `gx3d-160x1792x8h200`)
- **GPUs**: 8x NVIDIA H100 or H200 per node
- **NICs**: 8x ConnectX-6 Dx VFs (`101e`) per node, presented by the IBM Cloud hypervisor
- **Network**: Hopper-1 cluster network with 8 subnets (one per NIC), each in the `10.x.0.0/16` range
- **RDMA Transport**: RoCE v2
- **CNI Strategy**: `host-device` (full NIC passthrough to pod) + source-based routing

## Key Characteristics

- Nodes are **VMs** from the user's perspective — the NIC PFs are owned by the hypervisor, which presents VFs to the guest OS
- **SR-IOV operator is not used** — VFs are pre-created by the hypervisor
- **Firmware updates are not possible** (hypervisor-managed NICs)
- **PFC/ECN/QoS tuning is not needed** — handled by the IBM Cloud fabric
- **IOMMU must be enabled** on H100 nodes via MachineConfig
- **Source-based routing is critical** — each NIC is on a different subnet; without SBR, cross-subnet traffic uses the wrong egress NIC and is dropped by the IBM Cloud fabric (anti-spoofing)
- Uses a **custom SBR CNI binary** (`sbr-custom`) because stock SBR requires gateway from IPAM, but IBM Cloud DHCP does not provide a gateway

## Prerequisites

- OpenShift Container Platform >= 4.19 on IBM Cloud VPC
- Cluster-admin access via `oc` CLI
- Worker nodes of type `gx3d-160x1792x8h100` or `gx3d-160x1792x8h200`
- Hopper-1 cluster network configured with 8 subnets attached to each instance (instances must be stopped to attach cluster network interfaces)
- Validated regions: Frankfurt (eu-de-2, eu-de-fra02-a), Washington DC (us-east-3)

## Steps

Apply each step in order. Wait for operators to be ready before proceeding to the next step.

### Step 01: Operator Subscriptions

Install NFD, NVIDIA GPU Operator, and NVIDIA Network Operator.

```bash
oc apply -k 05-ocp-accelerator-operators/ibm-cloud-vpc/01-operator-subscriptions/
```

Verify:

```bash
oc get csv -n openshift-nfd
oc get csv -n nvidia-gpu-operator
oc get csv -n nvidia-network-operator
```

### Step 02: NFD Operands

Deploy `NodeFeatureDiscovery` and `NodeFeatureRule` CRs to label nodes with GPU and NIC features.

```bash
oc apply -k 05-ocp-accelerator-operators/ibm-cloud-vpc/02-nfd-operands/
```

Verify:

```bash
oc get nodes -l feature.node.kubernetes.io/pci-10de.present=true
oc get nodes -l feature.node.kubernetes.io/pci-15b3.present=true
```

### Step 14: NVIDIA Network Operator

Deploy `NicClusterPolicy` with MOFED drivers only. On IBM Cloud, the device plugin is not needed because VMs already have VFs from the hypervisor.

```bash
oc apply -k 05-ocp-accelerator-operators/ibm-cloud-vpc/14-nvidia-network-operator/
```

Verify:

```bash
oc get nicclusterpolicy
oc get pods -n nvidia-network-operator -l nvidia.com/ofed-driver -w
```

### Step 15: IBM Cloud Networking

Configures secondary high-speed networking:

- **MachineConfig** enabling `iommu=pt` on H100 nodes (MachineConfigPool `gpu-h100`)
- **sbr-custom DaemonSet** installing the custom SBR CNI binary on every node
- **8 NetworkAttachmentDefinitions** using host-device CNI with DHCP IPAM, one per NIC (`enp163s0` through `enp233s0`)

> **Before applying**, review `15-networking/network-attachment-definitions.yaml` and adjust device names, gateway IPs, and target namespace to match your cluster network configuration.

```bash
oc apply -k 05-ocp-accelerator-operators/ibm-cloud-vpc/15-networking/
```

Verify:

```bash
oc get mcp gpu-h100 -w                              # Wait for MCP rollout (nodes reboot)
oc get ds cni-sbr-custom-plugin -n openshift-multus  # SBR plugin installed
oc get net-attach-def                                # 8 NADs created
```

### Step 20: GPU Readiness

Wait for MOFED drivers to be fully loaded before deploying the GPU ClusterPolicy.

```bash
oc apply -k 05-ocp-accelerator-operators/ibm-cloud-vpc/20-gpu-readiness/
```

```bash
oc logs job/wait-for-mofed-ready -n llm-d-setup -f
```

### Step 21: GPU Operands

Deploy the GPU Operator `ClusterPolicy` (drivers, device plugin, DCGM, nvidia-peermem, toolkit).

```bash
oc apply -k 05-ocp-accelerator-operators/ibm-cloud-vpc/21-gpu-operands/
```

Verify:

```bash
oc get clusterpolicy gpu-cluster-policy -o jsonpath='{.status.state}'
oc get pods -n nvidia-gpu-operator
oc get nodes -o custom-columns=NAME:.metadata.name,GPU:.status.allocatable.nvidia\\.com/gpu
```

## Known Gotchas

1. **Namespace labels** — several operators expect `kubernetes.io/metadata.name` on their namespace. OCP does not always set this automatically.

2. **GPU driver pre-installed** — on IBM Cloud the GPU driver is baked into the node image. If your ClusterPolicy has `driver.enabled: true`, the driver container will conflict with the host driver. Set `driver.enabled: false` if using pre-installed drivers (the default ClusterPolicy in `common/21-gpu-operands/` has `driver.enabled: true` — you may need to patch it for IBM Cloud).

3. **DHCP missing gateway** — IBM Cloud's DHCP does not provide a gateway in the lease. Stock SBR CNI fails because it expects gateway from the IPAM result. The `sbr-custom` binary in this case study adds `gateway` and `preserveDefaultRoutes` fields to work around this.

4. **MachineConfigPool name** — the IOMMU MachineConfig targets the `gpu-h100` MCP. If your MCP is named differently (e.g., `gpu-h200`, `worker`), update `15-networking/machineconfig-iommu.yaml`.
