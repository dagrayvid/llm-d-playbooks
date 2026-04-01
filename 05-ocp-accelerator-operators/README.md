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

## Platform Selection

| Platform | Description |
|----------|-------------|
| `bare-metal-ib` | Bare-metal with InfiniBand |
| `bare-metal-roce` | Bare-metal with RoCE (SR-IOV) |
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

### Step 15: IBM Cloud Networking

| Platform | Action | Why |
|----------|--------|-----|
| bare-metal-ib | **skip** | Uses SR-IOV / RDMA shared devices instead |
| bare-metal-roce | **skip** | Uses SR-IOV / RDMA shared devices instead |
| ibm-cloud | apply | Attaches VF NICs to pods via host-device CNI |

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
