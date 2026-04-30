# Chapter 05: OCP Accelerator Operators

Install and configure GPU, RDMA, and networking operators on OpenShift Container Platform.

This chapter covers NFD (Node Feature Discovery), NVIDIA GPU Operator, NVIDIA Network Operator, and SR-IOV / host-device networking depending on platform. These operators are required on OCP but not on managed Kubernetes platforms (AKS, CKS).

## Credits

The operator manifests and automation in this chapter are adapted from [Infrabric-deployer](https://github.com/bbenshab/Infrabric-deployer) by [@bbenshab](https://github.com/bbenshab). The IBM Cloud networking configuration is based on the [PSAP Guide to RoCE on OCP for llm-d](https://docs.google.com/document/d/1YFnHMnb03E_0BVfMrwABMDnMFqbBBasYyXKPJqJnXV4).

## Prerequisites

- OpenShift Container Platform >= 4.19
- Cluster-admin access via `oc` CLI
- Worker nodes with NVIDIA GPUs
- For RDMA: Mellanox/NVIDIA ConnectX NICs (InfiniBand or RoCE)

### Requirements for GPUDirect RDMA (bare-metal)

GPUDirect RDMA enables direct DMA between GPUs and NICs over PCIe, bypassing the CPU. This is required for high-performance multi-node GPU workloads (NCCL, vLLM with disaggregated prefill, etc.). The following must be in place:

1. **IOMMU in passthrough mode** (`iommu=pt` kernel arg) — allows PCIe peer-to-peer DMA without address translation. Without this, the IOMMU blocks NIC↔GPU transfers.

2. **ACS disabled** (`pci=noacs` kernel arg + systemd service) — disables PCIe Access Control Services so P2P transactions route directly through PCIe switches instead of being redirected through the root complex. The `pci=noacs` kernel arg prevents the kernel from enabling ACS, while a systemd oneshot service clears ACS that firmware/BIOS enables during POST (common on Dell PowerEdge and other enterprise servers).

3. **Unlimited memlock** (`ContainerRuntimeConfig`) — CRI-O defaults the memlock ulimit to 8192 KB. RDMA memory registration for GPU buffers requires more. The `ContainerRuntimeConfig` sets the default to unlimited. Pods still need `IPC_LOCK` capability.

4. **Jumbo frames** (MTU 9000 on PFs) — optional but recommended. Improves GPUDirect RDMA throughput by ~5% (370→392 Gb/s on NDR200). PF MTUs must be set on the host before macvlan interfaces are created. Use the NMState operator ([Step 04](#step-04-nmstate-operator)) with `NodeNetworkConfigurationPolicy` resources.

5. **Source-based routing (SBR)** — required when each RoCE PF is on a separate VLAN/subnet. Without SBR, cross-subnet RDMA traffic cannot reach the gateway and connections fail. SBR ensures each NIC's traffic exits through its own gateway, allowing the switch to handle inter-VLAN routing.

Items 1–3 are applied automatically by [Step 03](#step-03-worker-node-gpurdma-config) via MachineConfig and ContainerRuntimeConfig. Item 4 uses the NMState operator (Step 04). Item 5 is integrated into the macvlan NADs (Step 15).

### Requirements for SR-IOV (bare-metal-roce with VFs)

If using the SR-IOV VF approach instead of macvlan + shared device plugin:

- **SR-IOV must be enabled in BIOS** (Intel VT-d / IOMMU and SR-IOV global enable). Check your server's BIOS/iDRAC settings under Integrated Devices or Virtualization.
- SR-IOV Network Operator must be installed (Step 10)

> **Note:** The current `bare-metal-roce` platform uses macvlan + RDMA shared device plugin, which does **not** require SR-IOV BIOS settings or VFs. The SR-IOV approach is available but not the default.

## Platform Selection

| Platform | Description |
|----------|-------------|
| `bare-metal-ib` | Bare-metal with InfiniBand |
| `bare-metal-roce` | Bare-metal with RoCE (macvlan + RDMA shared device plugin) |
| `ibm-cloud` | IBM Cloud VMs (host-device + NADs) |

Start with [Step 00](#step-00-discover-gpus--nics) to identify your hardware and determine which platform applies.

## Quick Start (automated)

### Shell Script

```bash
./05-ocp-accelerator-operators/install.sh --platform <bare-metal-ib|bare-metal-roce|ibm-cloud>
```

### ArgoCD (GitOps)

See [argocd/README.md](argocd/README.md) for setup. In short:

```bash
# 1. Install the OpenShift GitOps operator
# 2. Edit argocd/bootstrap/root-app.yaml to point to your platform overlay
# 3. Apply the bootstrap:
oc apply -k argocd/bootstrap/
```

---

## Manual Steps

Follow each step below in order, skipping any marked **skip** for your platform.

### Step 00: Discover GPUs & NICs

| Platform | Action | Why |
|----------|--------|-----|
| bare-metal-ib | apply | Identify hardware and NUMA topology |
| bare-metal-roce | apply | Identify hardware and NUMA topology |
| ibm-cloud | apply | Confirms NICs are VFs, shows GPU models |

Standalone script that probes cluster nodes for RDMA NICs and GPUs via sysfs -- no operators need to be installed yet. For each node it reports:
- **GPUs**: model (H100, A100, L40S, ...), PCI address, NUMA node
- **NICs**: interface name, link type (InfiniBand / Ethernet/RoCE), SR-IOV capability, whether the NIC is a VF (important for cloud VMs), NUMA node
- **NUMA topology**: which GPUs and NICs share the same NUMA node (important for optimal RDMA performance)

```bash
./05-ocp-accelerator-operators/00-discover-gpus-nics/discover-gpu-nic-topology.sh
```

Example output:

```
--- Node: worker-0 ---

  NICs:
  INTERFACE      PCI            LINK_LAYER   NUMA   SR-IOV   VFs     IS_VF CARRIER    RDMA_DEV
  ib_nic0        0000:86:00.0   InfiniBand   1      false    0       false 1          mlx5_0

  GPUs:
  PCI            DEV_ID   NUMA   MODEL
  0000:85:00.0   2330     1      H100 80GB HBM3 (SXM)

NUMA Topology (GPU <-> NIC affinity)
  Node: worker-0
    NUMA 1:
      GPUs: 0000:85:00.0(H100 80GB HBM3 (SXM))
      NICs: ib_nic0(mlx5_0)

Summary
  InfiniBand detected: true
  RoCE detected:       false
  SR-IOV capable:      false
  NICs are VFs:        false
  NVIDIA GPUs:         true
  GPU models:          H100 80GB HBM3 (SXM)

Recommended Platform Overlay
  -> bare-metal-ib
```

### Step 01: Operator Subscriptions

| Platform | Action | Why |
|----------|--------|-----|
| bare-metal-ib | apply | Required by all subsequent steps |
| bare-metal-roce | apply | Required by all subsequent steps |
| ibm-cloud | apply | Required by all subsequent steps |

Install NFD, NVIDIA GPU Operator, and NVIDIA Network Operator via OLM.

> **Re-installing?** OLM allows only one OperatorGroup per namespace. If these
> operators were previously installed, stale OperatorGroups will block new
> subscriptions. Clean them up first:
>
> ```bash
> for ns in openshift-nfd nvidia-gpu-operator nvidia-network-operator; do
>   oc get operatorgroup -n "$ns" -o name 2>/dev/null | while read og; do
>     echo "Deleting $og in $ns"
>     oc delete "$og" -n "$ns"
>   done
> done
> ```

```bash
oc apply -k 05-ocp-accelerator-operators/01-operators-nfd-gpu/base/
```

To check (CSVs may take a minute or two to appear):

```bash
oc get operatorgroup -n openshift-nfd
oc get operatorgroup -n nvidia-gpu-operator
oc get operatorgroup -n nvidia-network-operator
oc get csv -n openshift-nfd
oc get csv -n nvidia-gpu-operator
oc get csv -n nvidia-network-operator
```

### Step 02: NFD Operands

| Platform | Action | Why |
|----------|--------|-----|
| bare-metal-ib | apply | GPU and Network operators need NFD labels |
| bare-metal-roce | apply | GPU and Network operators need NFD labels |
| ibm-cloud | apply | GPU and Network operators need NFD labels |

Deploy `NodeFeatureDiscovery` and `NodeFeatureRule` custom resources. These label nodes with hardware features (NVIDIA GPUs via PCI vendor `10de`, Mellanox NICs via `15b3`, SR-IOV capability, RDMA modules).

```bash
oc apply -k 05-ocp-accelerator-operators/02-nfd-operands/base/
```

To check (labels may take ~60s to appear):

```bash
oc get nodes -l feature.node.kubernetes.io/pci-10de.present=true
oc get nodes -l feature.node.kubernetes.io/pci-15b3.present=true
```

### Step 03: Worker Node GPU/RDMA Config

| Platform | Action | Why |
|----------|--------|-----|
| bare-metal-ib | apply | GPUDirect RDMA requires IOMMU passthrough and ACS disabled |
| bare-metal-roce | apply | GPUDirect RDMA requires IOMMU passthrough and ACS disabled |
| ibm-cloud | **skip** | Hypervisor handles IOMMU/ACS; memlock is set by cloud runtime |

> **Warning: this step triggers worker node reboots.** The MachineConfig changes
> kernel boot arguments, which requires the MachineConfigPool to roll out updates
> to all worker nodes. Plan for downtime accordingly.

> **When is this needed?** Only if you plan to use GPUDirect RDMA (NCCL with
> `NCCL_NET_GDR_LEVEL`, `ib_write_bw --use_cuda`, etc.). If your workloads only
> use host-memory RDMA or don't use RDMA at all, you can skip this step. However,
> the memlock ulimit change is broadly useful for any RDMA workload.

Applies three resources:

- **MachineConfig `99-worker-gpu-rdma`** — adds kernel arguments:
  - `iommu=pt` — sets IOMMU to passthrough mode, allowing PCIe peer-to-peer DMA between GPUs and NICs without address translation
  - `pci=noacs` — prevents the kernel from enabling PCIe Access Control Services during PCI enumeration
- **MachineConfig `99-worker-disable-pcie-acs`** — installs a systemd oneshot service that clears ACS on all PCIe bridges at boot. Required because `pci=noacs` alone does not disable ACS that firmware/BIOS enables during POST (common on Dell PowerEdge and other enterprise servers with SR-IOV Global Enable in BIOS)
- **ContainerRuntimeConfig `worker-rdma-memlock`** — sets the default memlock ulimit to unlimited for all containers on worker nodes. Without this, CRI-O defaults to 8192 KB, which is too low for RDMA memory registration of GPU buffers. Pods still need the `IPC_LOCK` capability in their securityContext.

```bash
oc apply -k 05-ocp-accelerator-operators/03-worker-gpu-rdma-config/base/
```

**Combined master+worker nodes:** By default, these configs target the `worker` MCP only. If your cluster has nodes that serve as both master and worker (e.g., compact clusters, single-node, or lab setups), those nodes belong to the `master` MCP and will not receive the worker-targeted configs. Apply the master overlay in addition:

```bash
oc apply -k 05-ocp-accelerator-operators/03-worker-gpu-rdma-config/overlays/master/
```

To check:

```bash
# Watch the MachineConfigPool roll out (nodes will reboot)
oc get mcp worker -w

# After reboot, verify kernel args are applied
oc debug node/<worker-node> -- chroot /host cat /proc/cmdline | tr ' ' '\n' | grep -E 'iommu|noacs'

# Verify memlock is unlimited in a test pod
oc exec <pod> -- sh -c 'ulimit -l'
```

### Step 04: NMState Operator

| Platform | Action | Why |
|----------|--------|-----|
| bare-metal-ib | **skip** | IB fabric handles MTU at the subnet manager level |
| bare-metal-roce | apply | Sets jumbo frame MTU on RoCE PFs via declarative NNCPs |
| ibm-cloud | **skip** | Hypervisor handles NIC MTU |

> **Optional but recommended for RoCE.** Install the Kubernetes NMState Operator to
> declaratively manage host network interface settings (primarily MTU). NMState uses
> `NodeNetworkConfigurationPolicy` (NNCP) CRs to set desired state on node
> interfaces. This is safer than MachineConfig-based scripts because NMState
> properly manages NetworkManager profiles without interfering with OVN-Kubernetes
> or the OVS bridge (`br-ex`).

This step has two sub-steps because the `NMState` CR cannot be created until the
operator's CRD is registered.

**Step 04a: Install the operator**

```bash
oc apply -k 05-ocp-accelerator-operators/04-nmstate-operator/base/operator/
```

Wait for the operator CSV to be ready:

```bash
oc get csv -n openshift-nmstate -w
```

**Step 04b: Create the NMState instance**

Once the CSV shows `Succeeded`:

```bash
oc apply -k 05-ocp-accelerator-operators/04-nmstate-operator/base/instance/
```

To check:

```bash
# Wait for the NMState instance to be available
oc wait --for=condition=Available nmstate/nmstate --timeout=300s

# Verify daemon pods are running on all nodes
oc get pods -n openshift-nmstate
```

**Step 04c: Set MTU 9000 on RoCE PFs** (requires network-mapping from Step 13)

> Run this after the `network-mapping` ConfigMap exists in `llm-d-setup`. The job
> reads the mapping and creates a single `NodeNetworkConfigurationPolicy` (NNCP)
> that sets MTU 9000 on every listed PF. It only touches interfaces in the mapping
> — never the OVS uplink or management interfaces. The MTU env var defaults to
> `9000`; override it in the job spec if needed.

```bash
oc apply -k 05-ocp-accelerator-operators/04-nmstate-operator/base/nncp/
```

To check:

```bash
oc logs job/configure-roce-pf-mtu -n openshift-nmstate -f

# Verify NNCP applied
oc get nncp
oc get nnce
```

### Step 10: SR-IOV Operator

| Platform | Action | Why |
|----------|--------|-----|
| bare-metal-ib | **skip** | IB has a netlink PAGE_SIZE bug with SR-IOV; uses RDMA shared devices instead |
| bare-metal-roce | apply | Creates VFs on RoCE physical NICs |
| ibm-cloud | **skip** | NICs are already VFs from the hypervisor |

Install the SR-IOV Network Operator for RoCE VF management.

> **Re-installing?** Clean up stale OperatorGroups first (same issue as Step 01):
>
> ```bash
> oc get operatorgroup -n openshift-sriov-network-operator -o name 2>/dev/null | while read og; do
>   echo "Deleting $og"; oc delete "$og" -n openshift-sriov-network-operator
> done
> ```

```bash
oc apply -k 05-ocp-accelerator-operators/10-sriov-operator/base/
```

To check:

```bash
oc get operatorgroup -n openshift-sriov-network-operator
oc get csv -n openshift-sriov-network-operator
oc get pods -n openshift-sriov-network-operator
```

### Step 11: IB Interface Normalization (optional)

| Platform | Action | Why |
|----------|--------|-----|
| bare-metal-ib | optional | Cosmetic — operators use PCI addresses, not interface names |
| bare-metal-roce | optional | Cosmetic — operators use PCI addresses, not interface names |
| ibm-cloud | **skip** | Cloud NICs have stable names from the hypervisor |

Renames RDMA interfaces to consistent names (`ib_nic0`, `ib_nic1`, ...) via udev
rules in a MachineConfig. This makes interface names identical across nodes with
matching hardware. **Triggers worker node reboots.** Safe to skip — no downstream
steps depend on these names; operators and SR-IOV policies reference PCI addresses.

```bash
oc apply -k 05-ocp-accelerator-operators/11-ib-interface-normalization/base/
```

To check:

```bash
oc logs job/generate-ib-udev-rules -n llm-d-setup -f
oc get mcp worker -w
```

### Step 12: NIC Discovery

| Platform | Action | Why |
|----------|--------|-----|
| bare-metal-ib | apply | Feeds NIC data to Network Operator and SR-IOV config |
| bare-metal-roce | apply | Feeds NIC data to Network Operator and SR-IOV config |
| ibm-cloud | **skip** | NIC topology is known from the cloud provider |

DaemonSet that discovers RDMA-capable NICs on every node — PCI addresses, device IDs, link type (IB vs RoCE), carrier status. Results are stored as ConfigMaps (`nic-discovery-<node>`) in the `llm-d-setup` namespace and consumed by Step 13.

```bash
oc apply -k 05-ocp-accelerator-operators/12-nic-discovery/base/
```

To check:

```bash
oc get pods -n llm-d-setup -l app=nic-port-discovery -o wide
oc get configmap -n llm-d-setup -l app=nic-discovery
```

To inspect a specific node's discovery data:

```bash
oc get configmap -n llm-d-setup -l app=nic-discovery -o jsonpath='{.items[0].data.ports\.json}' | jq .
```

### Step 13: SR-IOV VF Config

| Platform | Action | Why |
|----------|--------|-----|
| bare-metal-ib | **skip** | IB doesn't use SR-IOV (see step 10) |
| bare-metal-roce | apply | Generates VF policies from Step 12 discovery data |
| ibm-cloud | **skip** | NICs are already VFs from the hypervisor |

Job that reads NIC discovery ConfigMaps from Step 12, then generates and applies `SriovNetworkNodePolicy` and `SriovNetwork` resources.

**Optional: explicit network mapping.** By default the generator auto-assigns sequential subnets to each PF (sorted alphabetically). If your cluster has a specific VLAN/subnet layout, create a `network-mapping` ConfigMap **before** running the generator Job. This ensures each PF's VFs get IP addresses on the correct subnet for their physical VLAN. PFs not listed in the mapping are excluded from SR-IOV configuration.

```bash
# Edit the mapping to match your cluster's PF→subnet layout:
vi 05-ocp-accelerator-operators/13-sriov-vf-config/base/network-mapping.yaml

# Apply it (optional — skip this for auto-discovery mode):
oc apply -f 05-ocp-accelerator-operators/13-sriov-vf-config/base/network-mapping.yaml
```

Then apply the generator:

```bash
oc apply -k 05-ocp-accelerator-operators/13-sriov-vf-config/base/
```

To check:

```bash
oc logs job/nic-resource-generator -n llm-d-setup -f
oc get sriovnetworknodepolicy -n openshift-sriov-network-operator
oc get sriovnetwork -n openshift-sriov-network-operator
```

### Step 14: NVIDIA Network Operator Config

| Platform | Action | Why |
|----------|--------|-----|
| bare-metal-ib | apply (base) | MOFED drivers + RDMA shared device plugin |
| bare-metal-roce | apply (base) | MOFED drivers + RDMA shared device plugin |
| ibm-cloud | apply (ibm-cloud overlay) | MOFED drivers only (no device plugin needed) |

Deploy `NicClusterPolicy` to configure MOFED drivers. The bare-metal base also auto-discovers the OFED driver version and generates RDMA shared device plugin config. IBM Cloud uses a simpler overlay with just MOFED drivers (no device plugin, since VMs already have VFs from the hypervisor).

```bash
# Bare metal
oc apply -k 05-ocp-accelerator-operators/14-nvidia-network-operator/base/

# IBM Cloud
oc apply -k 05-ocp-accelerator-operators/14-nvidia-network-operator/overlays/ibm-cloud/
```

To check:

```bash
oc logs job/configure-nic-policy -n nvidia-network-operator -f
oc get nicclusterpolicy
oc get pods -n nvidia-network-operator -l nvidia.com/ofed-driver -w
```

To verify the MOFED driver is loaded (once pods are Running):

```bash
oc exec -n nvidia-network-operator $(oc get pods -n nvidia-network-operator -l nvidia.com/ofed-driver -o jsonpath='{.items[0].metadata.name}') -- ofed_info -s
```

### Step 15: Platform-Specific Networking

| Platform | Action | Why |
|----------|--------|-----|
| bare-metal-ib | **skip** | Uses RDMA shared devices configured in Step 14 |
| bare-metal-roce | apply (`15-roce-macvlan`) | Creates macvlan networks + IP pools for each RoCE PF |
| ibm-cloud | apply (`15-ibm-cloud-networking`) | Attaches VF NICs to pods via host-device CNI |

#### bare-metal-roce: Macvlan + SBR + RDMA Shared Device Plugin

Creates `NetworkAttachmentDefinition` (NAD) and `IPPool` resources for each RoCE PF listed in the `network-mapping` ConfigMap (from Step 13). NADs are named **`llmd-roce-net-<n>`** by default in **`openshift-multus`** (env **`NAD_NAME_PREFIX`** overrides; avoids clobbering other `roce-net-*` NADs). Optional per-PF **`roceIndex`** in the mapping sets `<n>`; see `15-roce-macvlan/README.md`. Each PF still uses its real netdev as the macvlan **master**; pods attach by abstract NAD name. IP addresses come from NV-IPAM per-node blocks within each PF's subnet.

Each NAD uses a **chained CNI plugin** configuration:
1. **macvlan** — creates a sub-interface on the physical PF
2. **sbr-custom** — source-based routing to ensure cross-subnet RDMA traffic exits through the correct NIC's gateway

Source-based routing is required because each PF is on a separate VLAN/subnet. Without SBR, cross-rail RDMA traffic (e.g., GPU0's NIC on subnet A to GPU1's NIC on subnet B) cannot reach the gateway and the connection fails. SBR creates per-interface routing tables that force packets from each NIC's IP through that NIC's gateway, letting the switch handle inter-VLAN routing.

This step also deploys a DaemonSet (`cni-sbr-custom-plugin`) that installs the custom SBR CNI binary on every node.

This approach does **not** use SR-IOV VFs. Instead, pods share the physical function directly via the RDMA Shared Device Plugin (configured in Step 14) and macvlan CNI. NCCL/UCX handle GPU-NIC topology awareness automatically.

> **MTU note:** The macvlan MTU must not exceed the master PF's MTU. The default
> is `9000` (jumbo frames), which requires running Step 04c first to set PF MTUs
> via NMState. If your PFs are at 1500 (default) and you skipped Step 04c, set
> the job's `MTU` env var to `1500`. Jumbo frames improve GPUDirect RDMA
> throughput by ~5% (370→392 Gb/s on NDR200).

```bash
oc apply -k 05-ocp-accelerator-operators/15-roce-macvlan/base/
```

To check:

```bash
# SBR plugin installed on nodes
oc get ds cni-sbr-custom-plugin -n openshift-multus

# Configuration job
oc logs job/configure-macvlan-networks -n nvidia-network-operator -f

# Resources created
oc get ippools -n nvidia-network-operator
oc get net-attach-def -n openshift-multus
```

#### ibm-cloud: Host-Device Networking

Configure secondary high-speed networking using the host-device CNI plugin. On IBM Cloud, nodes are VMs where SR-IOV is at the hypervisor level, so we attach full NIC interfaces directly to pods via NetworkAttachmentDefinitions (NADs).

This step applies:
- **MachineConfig** enabling `iommu=pt` on H100 nodes (`gx3d-160x1792x8h100`)
- **sbr-custom DaemonSet** for source-based routing (required for WideEP / NVSHMEM cross-subnet traffic)
- **8 NADs** (one per NIC) using host-device with DHCP IPAM

**Before applying**, review `15-ibm-cloud-networking/base/network-attachment-definitions.yaml` and adjust device names, gateway IPs, and target namespace to match your cluster network configuration. The defaults are for `gx3d-160x1792x8h100` instances with devices `enp163s0`...`enp233s0` and gateways `10.0.0.1`...`10.7.0.1`.

```bash
oc apply -k 05-ocp-accelerator-operators/15-ibm-cloud-networking/base/
```

To check:

```bash
oc get mcp gpu-h100 -w
oc get ds cni-sbr-custom-plugin -n openshift-multus
oc get net-attach-def
```

### Step 20: Operator Readiness

| Platform | Action | Why |
|----------|--------|-----|
| bare-metal-ib | apply | GPU operator needs MOFED loaded first |
| bare-metal-roce | apply | GPU operator needs MOFED loaded first |
| ibm-cloud | apply | GPU operator needs MOFED loaded first |

Readiness gate jobs that wait for the NVIDIA Network Operator and MOFED drivers to be fully ready before deploying the GPU ClusterPolicy.

```bash
oc apply -k 05-ocp-accelerator-operators/20-operators-gpu-readiness/base/
```

To check:

```bash
oc logs job/wait-for-network-operator-ready -n llm-d-setup -f
oc logs job/wait-for-mofed-ready -n llm-d-setup -f
```

### Step 21: GPU Operands

| Platform | Action | Why |
|----------|--------|-----|
| bare-metal-ib | apply | Deploys GPU drivers, device plugin, monitoring |
| bare-metal-roce | apply | Deploys GPU drivers, device plugin, monitoring |
| ibm-cloud | apply | Deploys GPU drivers, device plugin, monitoring |

Deploy the GPU Operator `ClusterPolicy`, which triggers deployment of GPU drivers, device plugin, DCGM monitoring, GDRCopy, nvidia-peermem, and container toolkit.

```bash
oc apply -k 05-ocp-accelerator-operators/21-gpu-operands/base/
```

To check:

```bash
oc get clusterpolicy gpu-cluster-policy -o jsonpath='{.status.state}'
oc get pods -n nvidia-gpu-operator -w
oc get nodes -o custom-columns=NAME:.metadata.name,GPU:.status.allocatable.nvidia\\.com/gpu
```

---

## Verification

After all steps complete:

```bash
# GPU operator
oc get clusterpolicy
oc get pods -n nvidia-gpu-operator

# Network operator
oc get nicclusterpolicy
oc get pods -n nvidia-network-operator

# GPU resources on nodes
oc get nodes -o custom-columns=NAME:.metadata.name,GPU:.status.allocatable.nvidia\\.com/gpu

# IBM Cloud only: networking resources
oc get mcp gpu-h100
oc get ds cni-sbr-custom-plugin -n openshift-multus
oc get net-attach-def
```

Proceed to [06-validate-gpu-readiness](../06-validate-gpu-readiness/).
