# Case Study: Dell MX750c with NVIDIA B200 + BlueField-3 (RoCE)

## Environment

- **Platform**: Bare-metal OpenShift (2-node cluster)
- **Nodes**:
  - `dell-b200-1.bmas-001.lab.rdu2.dc.redhat.com`
  - `dell-b200-2.bmas-001.lab.rdu2.dc.redhat.com` (combined master+worker)
- **GPUs**: 8x NVIDIA B200 per node
- **NICs**: 10x Mellanox ConnectX-7 (mlx5) per node, NDR200 (400 Gb/s per port)
- **CPUs**: 2x Intel Xeon Platinum 8570 (56 cores each, 2.10 GHz)
- **RDMA Transport**: RoCE v2
- **CNI Strategy**: macvlan + RDMA shared device plugin + NV-IPAM + SBR

## Key Characteristics

- NICs are **physical functions** (PFs) directly visible to the OS, not hypervisor VFs
- Uses **macvlan + RDMA shared device plugin** instead of SR-IOV VFs — simpler, topology-agnostic, no firmware VF configuration needed
- **Firmware updates** are possible and may be required (known-good version: 32.43.1014+). See [`../../mellanox-firmware-update/`](../../mellanox-firmware-update/)
- **PFC/ECN/QoS tuning** is required for lossless RoCE on the physical fabric
- **IOMMU passthrough** and **ACS disable** are mandatory for GPUDirect RDMA
- **Source-based routing** is required — each PF is on a separate VLAN/subnet
- Each `/24` subnet with `PER_NODE_BLOCK_SIZE=20` supports up to 12 nodes

## BIOS Settings

| Setting | Location | Value | Notes |
|---------|----------|-------|-------|
| SR-IOV Global Enable | Integrated Devices | Enabled | Causes ACS on all PCIe bridges at POST |
| Virtualization Technology | Processor Settings | Enabled | Required for IOMMU (VT-d) |
| Kernel DMA Protection | Processor Settings | Disabled | If enabled, interferes with `iommu=pt` |
| Sub NUMA Cluster | Processor Settings | Disabled | Enabling splits NUMA nodes; needs topology re-evaluation |

**Unexplored alternative**: Disabling SR-IOV Global Enable would disable ACS at firmware level, removing the need for the systemd `setpci` service. Trade-off: SR-IOV VFs become unavailable. Since macvlan doesn't use VFs, this is viable but untested.

## Network Topology

### Addressing Scheme

L3 routed fabric — no VLANs. Each PF is assigned to a **rail** (0–9), and each rail gets its own `/16` range. Node identity determines the third octet.

```
subnet:  172.<16 + railId>.<hostId>.0/24
hostIp:  172.<16 + railId>.<hostId>.1
gateway: 172.<16 + railId>.<hostId>.254   (switch routed port)
```

Static routes per interface (configured via NMState NNCP):
- `172.<16 + railId>.0.0/16` via gateway — rail-specific
- `172.16.0.0/12` via gateway — ECMP fallback

### PF-to-Rail Mapping

| PF | Rail | Switch | dell-b200-1 subnet | dell-b200-2 subnet |
|----|------|--------|-------------------|-------------------|
| ens40f0np0 | 0 | sw02-leaf-gpu2 | 172.16.1.0/24 | 172.16.2.0/24 |
| ens41f0np0 | 1 | sw02-leaf-gpu2 | 172.17.1.0/24 | 172.17.2.0/24 |
| ens38f0np0 | 2 | sw02-leaf-gpu2 | 172.18.1.0/24 | 172.18.2.0/24 |
| ens37f0np0 | 3 | sw02-leaf-gpu2 | 172.19.1.0/24 | 172.19.2.0/24 |
| ens32f0np0 | 4 | sw01-leaf-gpu2 | 172.20.1.0/24 | 172.20.2.0/24 |
| ens31f0np0 | 5 | sw01-leaf-gpu2 | 172.21.1.0/24 | 172.21.2.0/24 |
| ens36f0np0 | 6 | sw01-leaf-gpu2 | 172.22.1.0/24 | 172.22.2.0/24 |
| ens35f0np0 | 7 | sw01-leaf-gpu2 | 172.23.1.0/24 | 172.23.2.0/24 |
| ens42f0np0 | 8 | sw02-leaf-gpu2 | 172.24.1.0/24 | 172.24.2.0/24 |
| ens34f0np0 | 9 | sw01-leaf-gpu2 | 172.25.1.0/24 | 172.25.2.0/24 |

Hosts: `dell-b200-1` = hostId 1, `dell-b200-2` = hostId 2. Gateway for each interface is `172.<16+rail>.<hostId>.254`.

Rails 0–3 and 8 connect through **sw02-leaf-gpu2**; rails 4–7 and 9 through **sw01-leaf-gpu2**.

`ens33f0np0` exists on the nodes but is not cabled/used for RoCE (11 PFs total, 10 mapped).

### GPU-NIC PIX Topology

| GPU | PIX NIC(s) | NUMA |
|-----|-----------|------|
| GPU0 | mlx5_0, mlx5_1 | 0 |
| GPU1 | mlx5_2 | 0 |
| GPU2 | mlx5_3 | 0 |
| GPU3 | mlx5_4, mlx5_5, mlx5_6 | 0 |
| GPU4 | mlx5_11 | 1 |
| GPU5 | mlx5_12 | 1 |
| GPU6 | mlx5_13, mlx5_14 | 1 |
| GPU7 | mlx5_15 | 1 |

PIX alignment is critical — using a NODE-relationship NIC instead of PIX costs ~100 Gb/s (~290 vs ~392 Gb/s).

## Prerequisites

- OpenShift Container Platform >= 4.19 (bare metal)
- Cluster-admin access via `oc` CLI
- Mellanox/NVIDIA ConnectX-7 NICs (BlueField-3 DPUs)
- Switch fabric configured with VLANs matching the PF-to-subnet mapping above
- Switch ports configured for jumbo frames (MTU 9000) end-to-end

## Steps

Apply each step in order. Steps are numbered to match the original playbook structure; gaps are intentional (skipped steps don't apply to this environment).

### Step 00: Discover GPUs & NICs

Run the hardware probe to identify NIC types, GPU models, and NUMA topology.

```bash
./05-ocp-accelerator-operators/common/00-discover-gpus-nics/discover-gpu-nic-topology.sh
```

### Step 01: Operator Subscriptions

Install NFD, NVIDIA GPU Operator, and NVIDIA Network Operator.

```bash
oc apply -k 05-ocp-accelerator-operators/bare-metal-dell-b200-bf3/01-operator-subscriptions/
```

Wait for subscriptions:

```bash
oc get csv -n openshift-nfd -w
oc get csv -n nvidia-gpu-operator -w
oc get csv -n nvidia-network-operator -w
```

### Step 02: NFD Operands

```bash
oc apply -k 05-ocp-accelerator-operators/bare-metal-dell-b200-bf3/02-nfd-operands/
```

### Step 03: Worker Node GPU/RDMA Config

> **Warning: triggers worker node reboots.** MachineConfig changes kernel boot arguments.

Applies:

- **MachineConfig `99-worker-gpu-rdma`** — `iommu=pt` + `pci=noacs` kernel args
- **MachineConfig `99-worker-disable-pcie-acs`** — systemd oneshot to clear firmware-set ACS at boot (required because Dell BIOS enables ACS on all PCIe bridges when SR-IOV Global Enable is on, and `pci=noacs` only prevents the *kernel* from enabling ACS, not firmware)
- **ContainerRuntimeConfig `worker-rdma-memlock`** — unlimited memlock for RDMA memory registration

```bash
oc apply -k 05-ocp-accelerator-operators/bare-metal-dell-b200-bf3/03-worker-gpu-rdma-config/base/
```

**Combined master+worker nodes** (e.g., dell-b200-2 is `control-plane,master,worker`):

```bash
oc apply -k 05-ocp-accelerator-operators/bare-metal-dell-b200-bf3/03-worker-gpu-rdma-config/overlays/master/
```

Wait for MCP rollout:

```bash
oc get mcp worker -w
```

After reboot, verify:

```bash
oc debug node/<worker> -- chroot /host cat /proc/cmdline | tr ' ' '\n' | grep -E 'iommu|noacs'
```

### Step 04: NMState Operator (Jumbo Frames)

Optional but recommended. Sets MTU 9000 on all RoCE PFs via declarative `NodeNetworkConfigurationPolicy`.

**Step 04a: Install the operator**

```bash
oc apply -k 05-ocp-accelerator-operators/bare-metal-dell-b200-bf3/04-nmstate-operator/base/operator/
oc get csv -n openshift-nmstate -w
```

**Step 04b: Create the NMState instance**

```bash
oc apply -k 05-ocp-accelerator-operators/bare-metal-dell-b200-bf3/04-nmstate-operator/base/instance/
oc wait --for=condition=Available nmstate/nmstate --timeout=300s
```

**Step 04c: Set MTU 9000 on RoCE PFs** (run after `network-mapping` ConfigMap exists from Step 13)

```bash
oc apply -k 05-ocp-accelerator-operators/bare-metal-dell-b200-bf3/04-nmstate-operator/base/nncp/
```

### Step 10: SR-IOV Operator

Install the SR-IOV Network Operator. Although this case study uses macvlan (not SR-IOV VFs) for pod networking, the operator provides infrastructure used by the VF config job.

```bash
oc apply -k 05-ocp-accelerator-operators/bare-metal-dell-b200-bf3/10-sriov-operator/
```

### Step 12: NIC Discovery

DaemonSet that discovers RDMA-capable NICs on every GPU node. Results are stored as ConfigMaps consumed by Step 13.

```bash
oc apply -k 05-ocp-accelerator-operators/bare-metal-dell-b200-bf3/12-nic-discovery/
```

Verify:

```bash
oc get configmap -n llm-d-setup -l app=nic-discovery
```

### Step 13: SBR Custom CNI Plugin

Installs the `sbr-custom` CNI binary on all nodes via DaemonSet. Required before Step 14 because the SR-IOV NADs chain `sbr-custom` for source-based + destination-based routing.

```bash
oc apply -k 05-ocp-accelerator-operators/bare-metal-dell-b200-bf3/13-sbr-custom-plugin/
```

Verify:

```bash
oc get ds cni-sbr-custom-plugin -n openshift-multus
```

### Step 14: SR-IOV VF Config / Network Mapping

Edit `14-sriov-vf-config/network-mapping.yaml` to match your PF-to-subnet layout, then apply:

```bash
oc apply -k 05-ocp-accelerator-operators/bare-metal-dell-b200-bf3/14-sriov-vf-config/
```

### Step 15: NVIDIA Network Operator

Deploys `NicClusterPolicy` with MOFED drivers + RDMA shared device plugin + NV-IPAM, and optionally enables the NIC Configuration Operator for persistent PFC/QoS settings.

> **Known issue: NIC Configuration Operator crashes on unresponsive devices.**
> The `nic-configuration-daemon` discovers all Mellanox PCI devices at startup
> and runs `flint` to query firmware/PSID on each one. If any device is
> unresponsive (e.g., the standalone ConnectX-7 at `0000:81:00.0` returns
> `ICMD bad parameter given`), the daemon crashes and enters CrashLoopBackOff.
> The `nicSelector` in `NicConfigurationTemplate` does not help because the
> crash occurs during device discovery, before template matching.
>
> **Workaround:** Disable the `nicConfigurationOperator` in `NicClusterPolicy`
> and apply PFC/buffer settings manually via `mlnx_qos` from the MOFED
> container after each reboot. The `ROCE_CC_PRIO_MASK_P1=0` setting (disabling
> DCQCN) is persistent via `mlxconfig` and survives reboots.
>
> **Upstream bug:** To be filed at
> [github.com/Mellanox/nic-configuration-operator](https://github.com/Mellanox/nic-configuration-operator/issues).

```bash
oc apply -k 05-ocp-accelerator-operators/bare-metal-dell-b200-bf3/15-nvidia-network-operator/
```

Verify MOFED is loaded:

```bash
oc get pods -n nvidia-network-operator -l nvidia.com/ofed-driver -w
oc exec -n nvidia-network-operator $(oc get pods -n nvidia-network-operator -l nvidia.com/ofed-driver -o jsonpath='{.items[0].metadata.name}') -- ofed_info -s
```

### Step 16: RoCE Macvlan + SBR (macvlan path only, not used with SR-IOV)

Creates macvlan `NetworkAttachmentDefinition` and `IPPool` resources for each RoCE PF.

Each NAD uses a chained CNI config:
1. **macvlan** — sub-interface on the physical PF
2. **sbr-custom** — source-based routing to force cross-subnet RDMA through the correct NIC's gateway

Also deploys the `sbr-custom` CNI binary via DaemonSet.

> **MTU note:** macvlan MTU must not exceed PF MTU. Default is 9000 (requires Step 04c first). Set the job's `MTU` env var to `1500` if PFs are still at default MTU.

```bash
oc apply -k 05-ocp-accelerator-operators/bare-metal-dell-b200-bf3/15-roce-macvlan/base/
```

Verify:

```bash
oc get ds cni-sbr-custom-plugin -n openshift-multus
oc get ippools -n nvidia-network-operator
oc get net-attach-def -n openshift-multus
```

### Step 20: GPU Readiness

```bash
oc apply -k 05-ocp-accelerator-operators/bare-metal-dell-b200-bf3/20-gpu-readiness/
oc logs job/wait-for-mofed-ready -n llm-d-setup -f
```

### Step 21: GPU Operands

```bash
oc apply -k 05-ocp-accelerator-operators/bare-metal-dell-b200-bf3/21-gpu-operands/
```

Verify:

```bash
oc get clusterpolicy gpu-cluster-policy -o jsonpath='{.status.state}'
oc get nodes -o custom-columns=NAME:.metadata.name,GPU:.status.allocatable.nvidia\\.com/gpu
```

## RDMA Validation

After all steps complete, proceed to [07-rdma-validation/](../../07-rdma-validation/) for RDMA connectivity and bandwidth tests (`ib_write_bw`, cross-node matrix, GPU-NIC topology checks).

## Validated Performance

| Test | GPU-NIC Relationship | Subnets | MTU | Bandwidth |
|------|---------------------|---------|-----|-----------|
| Same-rail GPUDirect | GPU0 -> mlx5_0 (PIX) | same | 1500 | ~370 Gb/s |
| Same-rail GPUDirect | GPU0 -> mlx5_0 (PIX) | same | 9000 | ~388 Gb/s |
| Cross-rail (wrong NIC) | GPU0 -> mlx5_0 (PIX) <-> GPU1 -> mlx5_1 (NODE) | different | 9000 | ~290 Gb/s |
| **Cross-rail (correct)** | **GPU0 -> mlx5_0 (PIX) <-> GPU1 -> mlx5_2 (PIX)** | **different + SBR** | **9000** | **392 Gb/s** |

Key findings:
- **PIX GPU-NIC alignment is critical** — NODE relationship costs ~100 Gb/s
- **Switch inter-VLAN routing adds zero penalty** when PIX alignment is correct
- **SBR is mandatory** for cross-subnet RDMA
- **Jumbo frames (MTU 9000)** improve throughput by ~5%

## Problems Encountered and Solutions

Detailed troubleshooting notes covering ACS, IOMMU, memlock, MTU validation, and more are in [`../../test-logs/rdma-perf-journal.md`](../../test-logs/rdma-perf-journal.md).

Key issues that were solved during bring-up:

1. **SR-IOV VF approach abandoned** — switched to macvlan + RDMA shared device plugin for simplicity
2. **NicClusterPolicy wiped by partial `oc apply`** — consolidated into a single job that uses `oc patch --type=merge`
3. **Python 3.6 in ose-cli image** — rewrote scripts to use `json.dumps()` instead of `yaml.dump()`
4. **Macvlan MTU validation failure** — PF MTU must be set to 9000 *before* macvlan NADs with `mtu: 9000`
5. **GPUDirect RDMA `ENOMEM`** — ACS was enabled on PCIe bridges; fixed with `pci=noacs` + systemd `setpci` service
6. **GPUDirect RDMA `LOC_PROT_ERR`** — also ACS; P2P blocked by IOMMU in full translation mode; fixed with `iommu=pt`
7. **memlock not raised by `IPC_LOCK` alone** — CRI-O sets the hard limit; `ContainerRuntimeConfig` required
8. **In-pod GPU-NIC topology mapping** — created diagnostic scripts to map GPU -> HCA -> PF -> macvlan -> IP
9. **GID index inconsistency** — varies per node/device; NCCL auto-detects; do NOT set `NCCL_IB_GID_INDEX` globally
10. **SR-IOV operator scheduling deadlock during VF reconfiguration** — when the SR-IOV config daemon drains/cordons the master node for a firmware change (e.g., reducing VFs from 16 to 8), the operator pod itself becomes unschedulable if it has a `nodeSelector` pinning it to master nodes. This creates a deadlock: the operator must be running to orchestrate the reconfiguration, but it can't run because the only master is cordoned. Fix: remove the `nodeSelector` so the operator can schedule on any node:
    ```bash
    oc patch deployment sriov-network-operator -n openshift-sriov-network-operator \
      --type=json -p='[{"op":"remove","path":"/spec/template/spec/nodeSelector"}]'
    ```
    This allows the operator to float to whichever node is schedulable during rolling NIC firmware updates. The `MaxParallelNodeConfiguration` setting (default 1) in `SriovOperatorConfig` controls how many nodes are processed concurrently — with only one node draining at a time, the operator can always run on the other.
