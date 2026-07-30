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
- **IOMMU is not needed** — the hypervisor handles IOMMU for the guest VMs
- **Source-based routing is critical** — each NIC is on a different subnet; without SBR, cross-subnet traffic uses the wrong egress NIC and is dropped by the IBM Cloud fabric (anti-spoofing)
- Uses a **custom SBR CNI binary** (`sbr-custom`) because stock SBR requires gateway from IPAM, but IBM Cloud DHCP does not provide a gateway

## Network Topology

Each node has 8 high-speed NICs (`enp163s0` through `enp233s0`), each on a separate IBM Cloud cluster network subnet. The subnets use `10.x.0.0/16` addressing with gateways at `10.x.0.1`. Traffic between subnets on different nodes must egress through the correct NIC — the IBM Cloud fabric enforces anti-spoofing rules that drop packets from an unexpected source IP.

## Prerequisites

- OpenShift Container Platform >= 4.19 on IBM Cloud VPC
- Cluster-admin access via `oc` CLI
- Worker nodes of type `gx3d-160x1792x8h100` or `gx3d-160x1792x8h200`

### IBM Cloud cluster network setup

Before deploying OCP operators, the high-speed RDMA network must be configured at the IBM Cloud level:

1. **Create a cluster network** — in your IBM Cloud VPC, create a cluster network (Hopper-1 type) with 8 subnets. Each subnet provides a dedicated RDMA fabric rail.
2. **Attach cluster network interfaces** — for each bare-metal instance, create 8 cluster network interface attachments (one per subnet). The instances must be **stopped** to attach cluster network interfaces. After attaching, start the instances.
3. **Verify NICs appear in the guest OS** — after boot, each node should have 8 additional NICs (`enp163s0` through `enp233s0`) visible via `ip link`. These are the hypervisor-managed VFs for RDMA.

See the [IBM Cloud documentation on cluster networks](https://cloud.ibm.com/docs/vpc?topic=vpc-about-cluster-network) for detailed instructions.

- Validated regions: Frankfurt (eu-de-2, eu-de-fra02-a), Washington DC (us-east-3)

## Steps

Apply each step in order. Wait for operators to be ready before proceeding to the next step.

### Step 01: Operator Subscriptions

Install NFD, NVIDIA GPU Operator, and NVIDIA Network Operator.

```bash
oc apply -k 03-accelerator-operator-config/ocp-ibm-cloud-vpc/01-operator-subscriptions/
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
oc apply -k 03-accelerator-operator-config/ocp-ibm-cloud-vpc/02-nfd-operands/
```

Verify:

```bash
oc get nodes -l feature.node.kubernetes.io/pci-10de.present=true
oc get nodes -l feature.node.kubernetes.io/pci-15b3.present=true
```

### Step 14: NVIDIA Network Operator

Deploy `NicClusterPolicy` with MOFED drivers and the RDMA shared device plugin. The device plugin advertises the hypervisor-managed ConnectX-6 Dx VFs (`101e`) as `nvidia.com/roce` resources so pods can request them.

```bash
oc apply -k 03-accelerator-operator-config/ocp-ibm-cloud-vpc/14-nvidia-network-operator/
```

Verify:

```bash
oc get nicclusterpolicy
oc get pods -n nvidia-network-operator -l nvidia.com/ofed-driver -w
```

### Step 15: IBM Cloud Networking

Configures secondary high-speed networking:

- **MachineConfig (memlock)** setting unlimited memlock via CRI-O for RDMA memory registration (MachineConfigPool `gpu-h100`)
- **sbr-custom DaemonSet** installing the custom SBR CNI binary on every node
- **8 NetworkAttachmentDefinitions** using host-device CNI with DHCP IPAM, one per NIC (`enp163s0` through `enp233s0`)

> **Note on RDMA memory pinning:** RDMA requires the ability to pin (lock) memory. There are two ways to achieve this: (1) setting unlimited memlock at the node level via CRI-O (this case study's approach — no special SCC needed), or (2) granting the `IPC_LOCK` capability per pod via a custom SCC. The node-level approach is simpler for dedicated GPU nodes.

> **Before applying**, review `15-networking/network-attachment-definitions.yaml` and adjust device names, gateway IPs, and target namespace to match your cluster network configuration.

> **Warning: triggers GPU worker node reboot.** The memlock MachineConfig changes CRI-O configuration. Only nodes in the `gpu-h100` MachineConfigPool are rebooted.

```bash
oc apply -k 03-accelerator-operator-config/ocp-ibm-cloud-vpc/15-networking/
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
oc apply -k 03-accelerator-operator-config/ocp-ibm-cloud-vpc/20-gpu-readiness/
```

```bash
oc logs job/wait-for-mofed-ready -n llm-d-setup -f
```

### Step 21: GPU Operands

Deploy the GPU Operator `ClusterPolicy` (drivers, device plugin, DCGM, nvidia-peermem, toolkit).

```bash
oc apply -k 03-accelerator-operator-config/ocp-ibm-cloud-vpc/21-gpu-operands/
```

Verify:

```bash
oc get clusterpolicy gpu-cluster-policy -o jsonpath='{.status.state}'
oc get pods -n nvidia-gpu-operator
oc get nodes -o custom-columns=NAME:.metadata.name,GPU:.status.allocatable.nvidia\\.com/gpu
```

## RDMA Validation

After all steps complete, proceed to [Chapter 04: Validate Cluster](../../04-validate-cluster-ready/) for RDMA connectivity and bandwidth tests.

## Known Gotchas

1. **DHCP missing gateway** — IBM Cloud's DHCP does not provide a gateway in the lease. Stock SBR CNI fails because it expects gateway from the IPAM result. The `sbr-custom` binary in this case study adds `gateway` and `preserveDefaultRoutes` fields to work around this.

2. **MachineConfigPool name** — the memlock MachineConfig targets the `gpu-h100` MCP. If your MCP is named differently (e.g., `gpu-h200`, `worker`), update `15-networking/machineconfig-memlock.yaml`.

3. **Namespace labels** — several operators expect `kubernetes.io/metadata.name` on their namespace. OCP does not always set this automatically.
