# Case Study: Bare-Metal B200 with ipvlan + Shared RDMA Device Plugin

## Environment

- **Platform**: Bare-metal OpenShift 4.21
- **GPU nodes**: 2x Dell B200 workers, 8x NVIDIA B200 GPUs per node
- **NICs per node**: 8x NVIDIA BlueField-3 SuperNICs (ConnectX-7 cores), in legacy NIC mode
- **RDMA Transport**: RoCE v2
- **CNI Strategy**: ipvlan L2 + NVIDIA RDMA shared device plugin (no SR-IOV)

## Key Characteristics

- **ipvlan replaces SR-IOV** — uses ipvlan L2 sub-interfaces on the physical functions instead of SR-IOV VFs. This avoids a firmware-level bug in BF3 SuperNICs (see [Why ipvlan instead of SR-IOV](#why-ipvlan-instead-of-sr-iov) below)
- **Shared RDMA device plugin** — gives each pod access to all RDMA devices on the host (`/dev/infiniband/*`). Pods request `rdma/rdma_shared_device_a: 1` as an access token, not a dedicated device
- **All 8 rail NADs per pod** — every inference pod must attach all 8 ipvlan NADs regardless of TP size, because NIXL requires a RoCE GID on every GPU-affine mlx5 device (see [Why all 8 rails per pod](#why-all-8-rails-per-pod) below)
- **No SR-IOV operator**, no VFs, no eSwitch steering
- **IOMMU passthrough** and **memlock unlimited** are still required for GPUDirect RDMA

## Why ipvlan Instead of SR-IOV

BF3 SuperNICs in legacy NIC mode have a firmware-level bug: the eSwitch cannot set up QP steering for a second VF on the same PF while the first VF has an active RDMA QP. This causes `IBV_WC_RETRY_EXCEEDED` (RC transport) or `Failed to modify QP to RTR` (UC transport) on the second VF.

The ipvlan + shared device plugin approach bypasses this entirely:

- **No VFs** → no eSwitch VF steering
- Multiple pods create QPs directly on the PF
- PF handles multiple QPs natively (standard RDMA behavior)
- ipvlan gives each pod its own IP for RoCE GID registration

## Why All 8 Rails Per Pod

NIXL uses `ibv_reg_dmabuf_mr` to register GPU KV cache memory for zero-copy RDMA transfers between prefill and decode engines. This kernel call requires the RDMA device (`mlx5_X`) and the GPU to share the same PCIe root complex — the DMA-BUF file descriptor is only valid within that physical topology.

Each ipvlan interface registers a RoCE v2 GID on its parent mlx5 device. Without an ipvlan interface, the mlx5 device has no GID and NIXL cannot use it. If a pod only has rail 0 attached, only `mlx5_0` gets a GID. A pod assigned to GPU3 (affine to `mlx5_6` via rail 6) tries to register its KV cache on `mlx5_0` instead and gets `ibv_reg_dmabuf_mr: Resource temporarily unavailable` because the PCIe root complexes don't match.

Attaching all 8 rail NADs gives every mlx5 device a GID. NIXL then registers dmabuf on whichever device is affine to the pod's GPU.

## Network Topology

### Architecture

```
Pod                          Host
┌──────────────────┐         ┌──────────────────────────┐
│  vLLM container  │         │                          │
│                  │         │  ens40f0np0 (PF)         │
│  net1 (ipvlan)   │────────▶│    │                     │
│  172.16.0.x/24   │  ipvlan │    └── mlx5_0 (RDMA)    │
│                  │   L2    │                          │
│  mlx5_0 (shared) │────────▶│  /dev/infiniband/*      │
│                  │  shared │  (all RDMA devices)     │
│  eth0 (pod net)  │  device │                          │
│  10.128.x.x      │  plugin │  OVN pod network       │
└──────────────────┘         └──────────────────────────┘
```

- **ipvlan L2**: Creates a sub-interface on the PF with its own IP. PF stays on the host. Multiple pods share the same PF.
- **Shared RDMA device plugin**: Gives pods access to ALL RDMA devices (`/dev/infiniband/*`). No VFs, no eSwitch steering.
- **GID registration**: The ipvlan IP registers a RoCE v2 GID on the PF's RDMA device. RDMA traffic uses this GID for cross-node routing.

### GPU-NIC PCIe Affinity

For optimal GPUDirect RDMA performance, each GPU should use its PCIe-affine NIC. The table below shows the mapping for this cluster (determined via `nvidia-smi topo -m`):

| GPU | NIC PF | Rail | PLX Root |
|-----|--------|------|----------|
| GPU0 (1b:00.0) | ens40f0np0 (18:00.0) | 0 | 0000:16:00.0 |
| GPU1 (3c:00.0) | ens41f0np0 (3a:00.0) | 1 | 0000:38:00.0 |
| GPU2 (4b:00.0) | ens38f0np0 (4d:00.0) | 2 | 0000:49:00.0 |
| GPU3 (5c:00.0) | ens37f0np0 (5d:00.0) | 3 | 0000:5a:00.0 |
| GPU4 (9a:00.0) | ens32f0np0 (9b:00.0) | 4 | 0000:98:00.0 |
| GPU5 (bb:00.0) | ens31f0np0 (ba:00.0) | 5 | 0000:b8:00.0 |
| GPU6 (cd:00.0) | ens36f0np0 (ca:00.0) | 6 | 0000:c8:00.0 |
| GPU7 (dc:00.0) | ens35f0np0 (db:00.0) | 7 | 0000:d8:00.0 |

## Prerequisites

- OpenShift Container Platform >= 4.21 (bare metal)
- Cluster-admin access via `oc` CLI
- NVIDIA BlueField-3 SuperNICs in legacy NIC mode (or ConnectX-7)
- RoCE-capable switching with L2 VLANs (one VLAN per rail) or L3 routed ports
- GPU worker nodes labeled with a role label (e.g., `node-role.kubernetes.io/b200-gpu`)

## Steps

Apply each step in order. Steps are numbered to match other case studies for cross-reference.

### Step 00: Discover GPUs & NICs

Run the hardware probe to identify NIC types, GPU models, and NUMA topology.

```bash
./03-accelerator-operator-config/common/00-discover-gpus-nics/discover-gpu-nic-topology.sh
```

### Step 01: Operator Subscriptions

Install NFD, NVIDIA GPU Operator, and NVIDIA Network Operator.

```bash
oc apply -k 03-accelerator-operator-config/bare-metal-b200-ipvlan/01-operator-subscriptions/
```

Wait for all three operators to reach `Succeeded`:

```bash
oc get csv -n openshift-nfd -w
oc get csv -n nvidia-gpu-operator -w
oc get csv -n nvidia-network-operator -w
```

### Step 02: NFD Operands

Create the NodeFeatureDiscovery instance and NodeFeatureRules for GPU and NIC detection.

```bash
oc apply -k 03-accelerator-operator-config/bare-metal-b200-ipvlan/02-nfd-operands/
```

Verify NFD labels are applied to GPU nodes:

```bash
oc get nodes -l feature.node.kubernetes.io/pci-10de.present -o name
oc get nodes -l feature.node.kubernetes.io/pci-15b3.present -o name
```

### Step 03: Worker GPU/RDMA Config

> **Warning: triggers GPU worker node reboots.** MachineConfig changes kernel boot arguments. Only nodes in your GPU worker MachineConfigPool are rebooted.

**Before applying**, verify your MachineConfigPool exists and update the `machineconfiguration.openshift.io/role` labels in the MachineConfig YAMLs if your MCP name differs from `b200-gpu`.

This step applies two MachineConfigs:

1. **`99-b200-gpu-iommu-pt`** — `iommu=pt` (IOMMU passthrough for GPUDirect RDMA)
2. **`99-b200-gpu-crio-memlock`** — CRI-O memlock unlimited (required for RDMA memory registration)

```bash
oc apply -k 03-accelerator-operator-config/bare-metal-b200-ipvlan/03-worker-gpu-rdma-config/
```

Watch the rollout:

```bash
oc get mcp b200-gpu -w
```

After reboot, verify:

```bash
# IOMMU
oc debug node/<gpu-node> -- chroot /host cat /proc/cmdline | tr ' ' '\n' | grep iommu

# memlock
oc debug node/<gpu-node> -- chroot /host bash -c 'ulimit -l'
```

### Step 15: NVIDIA Network Operator (NicClusterPolicy)

Deploys the `NicClusterPolicy` with:
- **MOFED drivers** (DOCA 3.4.0) — containerized Mellanox OFED drivers for RoCE
- **RDMA shared device plugin** — exposes all Mellanox RDMA devices as `rdma/rdma_shared_device_a`

```bash
oc apply -k 03-accelerator-operator-config/bare-metal-b200-ipvlan/15-nvidia-network-operator/
```

Wait for MOFED driver pods on all GPU nodes:

```bash
oc get pods -n nvidia-network-operator -l nvidia.com/ofed-driver -w
```

Verify RDMA resources are advertised:

```bash
oc get nodes -l node-role.kubernetes.io/b200-gpu \
  -o custom-columns=NAME:.metadata.name,RDMA:.status.allocatable.rdma/rdma_shared_device_a
```

Each GPU node should report `1000` (or `1k`) allocatable RDMA devices.

### Step 16: ipvlan Networking

Deploy 8 ipvlan L2 NetworkAttachmentDefinitions, one per rail (GPU-NIC pair).

> **Before applying**, review `16-ipvlan-networking/network-attachment-definitions.yaml` and update:
> - `master` fields to match your NIC interface names
> - IP ranges to match your network addressing
> - The NADs are namespaced — apply them in your workload namespace

```bash
oc apply -k 03-accelerator-operator-config/bare-metal-b200-ipvlan/16-ipvlan-networking/
```

Verify:

```bash
oc get net-attach-def
```

You should see 8 NADs: `ipvlan-rail0` through `ipvlan-rail7`.

### Step 20: GPU Readiness

Wait for MOFED drivers to be ready before the GPU Operator starts loading its drivers.

```bash
oc apply -k 03-accelerator-operator-config/bare-metal-b200-ipvlan/20-gpu-readiness/
```

### Step 21: GPU Operands

Deploy the GPU Operator ClusterPolicy.

```bash
oc apply -k 03-accelerator-operator-config/bare-metal-b200-ipvlan/21-gpu-operands/
```

Wait for the ClusterPolicy to reach `ready` state:

```bash
oc get clusterpolicy gpu-cluster-policy -w
```

Verify GPUs are available:

```bash
oc get nodes -l node-role.kubernetes.io/b200-gpu \
  -o custom-columns=NAME:.metadata.name,GPU:.status.allocatable.nvidia\\.com/gpu
```

## RDMA Validation

After all steps complete, proceed to [Chapter 04: Validate Cluster](../../04-validate-cluster-ready/) for RDMA connectivity and bandwidth tests.

### Quick GID verification

After deploying a test pod with all 8 rail NADs and `rdma/rdma_shared_device_a: 1`, verify that each mlx5 device has a RoCE v2 GID registered from its ipvlan IP:

```bash
kubectl exec <pod> -- bash -c '
for dev in /sys/class/infiniband/mlx5_*; do
    d=$(basename $dev)
    for i in 0 1 2 3 4 5; do
        gid=$(cat $dev/ports/1/gids/$i 2>/dev/null)
        type=$(cat $dev/ports/1/gid_attrs/types/$i 2>/dev/null)
        [ -n "$gid" ] && [ "$gid" != "0000:0000:0000:0000:0000:0000:0000:0000" ] && \
          echo "$d GID[$i]: $gid $type"
    done
done'
```

Look for `RoCE v2` GIDs corresponding to the ipvlan IP addresses on each mlx5 device.

### Cross-node bandwidth test

Expected: 370+ Gb/s per rail at line rate with `ib_write_bw`.

## Pod Annotations

Inference pods must be annotated with all 8 rail NADs. Example:

```yaml
annotations:
  k8s.v1.cni.cncf.io/networks: |
    [
      {"name": "ipvlan-rail0"},
      {"name": "ipvlan-rail1"},
      {"name": "ipvlan-rail2"},
      {"name": "ipvlan-rail3"},
      {"name": "ipvlan-rail4"},
      {"name": "ipvlan-rail5"},
      {"name": "ipvlan-rail6"},
      {"name": "ipvlan-rail7"}
    ]
```

Pods also need:
- `rdma/rdma_shared_device_a: 1` in resource requests/limits
- `securityContext.capabilities.add: ["IPC_LOCK"]`

## L3 Routed Switching (Alternative)

The manifests in this case study use **L2 switching** — both nodes on the same VLAN per rail, one shared /24 subnet, no gateway routes. This is the simpler configuration.

If your switch uses **L3 routed ports** (each port has its own /24 subnet), you need per-node NADs because the gateway IP differs per node. For example, with L3 routing:

- Node 1 rail 0: range `172.16.1.0/24`, gateway `172.16.1.254`
- Node 2 rail 0: range `172.16.2.0/24`, gateway `172.16.2.254`

This results in 16 NADs (8 rails × 2 nodes) instead of 8, and pods must be annotated with the correct node-specific NAD set. This is more complex to manage and requires knowing which node a pod will run on at deployment time.

L2 switching eliminates per-node NADs and is recommended where possible.

## Problems Encountered and Solutions

> **TODO**: Document issues encountered during bring-up.
