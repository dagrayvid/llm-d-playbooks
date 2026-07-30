# Case Study: Bare-Metal Dell XE8640 with SR-IOV

## Environment

- **Platform**: Bare-metal OCP 4.21, SNO control plane + 2 Dell XE8640 workers
- **GPUs**: 4x NVIDIA H100 SXM5 per node
- **NICs**: 1x ConnectX-6 Dx dual-port per node (`101d`, mlx5 driver)
  - Port 1: `eno12399np0` — VLAN 103
  - Port 2: `eno12409np1` — VLAN 103
- **RDMA Transport**: RoCE v2
- **CNI Strategy**: SR-IOV (8 VFs per port, `deviceType: netdevice`)
- **IPAM**: whereabouts (static range allocation per VLAN)

## Key Characteristics

- **Minimal SR-IOV example** — 2 ports, static manifests, no dynamic NIC discovery or generator scripts
- **VLAN tagging required** — switch ports are configured for tagged traffic only; untagged frames are dropped. VLANs are set in the `SriovNetwork` resources.
- **No SBR routing needed** — each VLAN maps to its own subnet, so there is no cross-subnet routing ambiguity
- **ConnectX-6 NICs are dedicated to RDMA** — the OCP pod network runs on a separate Intel NIC (`ens1f0`)

## Network Topology

### VLAN and Subnet Scheme

| Port | Interface | VLAN | Subnet | IPAM Range |
|------|-----------|------|--------|------------|
| 1 | `eno12399np0` | 103 | `192.168.103.0/24` | `.10` – `.250` |
| 2 | `eno12409np1` | 103 | `192.168.103.0/24` | `.10` – `.250` |

### GPU–NIC PCIe Topology

Both ConnectX-6 ports are on NUMA node 0. GPUs are split across NUMA 0 and NUMA 1:

```
NUMA 0
├── GPU 0  (4e:00.0)
├── GPU 1  (5f:00.0)
└── ConnectX-6 Dx (27:00.0 / 27:00.1)
    ├── Port 1: eno12399np0
    └── Port 2: eno12409np1

NUMA 1
├── GPU 2  (cb:00.0)
└── GPU 3  (db:00.0)
```

GPUs 2 and 3 on NUMA 1 have no local NIC — RDMA traffic crosses the NUMA interconnect. This is typical for 4-GPU nodes with a single dual-port NIC.

## Prerequisites

- OpenShift Container Platform >= 4.21
- Cluster-admin access via `oc` CLI
- GPU worker nodes with ConnectX-6 Dx NICs (`15b3:101d`)
- Switch ports configured for VLAN-tagged traffic (VLANs 103, 104)

## Steps

Wait for operators to be ready before proceeding. Note that Step 15 (NicClusterPolicy / MOFED) must be applied **before** Step 14 (SR-IOV VF policies) — MOFED must load before the SR-IOV config daemon starts.

### Step 01: Operator Subscriptions

Install NFD, NVIDIA GPU Operator, NVIDIA Network Operator, and the SR-IOV Network Operator.

```bash
oc apply -k 03-accelerator-operator-config/ocp-bare-metal-sriov/01-operator-subscriptions/
```

Verify:

```bash
oc get csv -n openshift-nfd
oc get csv -n nvidia-gpu-operator
oc get csv -n nvidia-network-operator
oc get csv -n openshift-sriov-network-operator
```

### Step 02: NFD Operands

Deploy `NodeFeatureDiscovery` and `NodeFeatureRule` CRs to label nodes with GPU and NIC features.

```bash
oc apply -k 03-accelerator-operator-config/ocp-bare-metal-sriov/02-nfd-operands/
```

Verify:

```bash
oc get nodes -l feature.node.kubernetes.io/pci-10de.present=true
oc get nodes -l feature.node.kubernetes.io/pci-15b3.present=true
```

### Step 03: Worker GPU/RDMA Config

Creates a custom `gpu-worker` MachineConfigPool and applies MachineConfigs for:

- **`iommu=pt`** — required for GPUDirect RDMA on bare-metal
- **Unlimited memlock** — CRI-O ulimit so RDMA memory registration doesn't fail

> **Before applying**, label your GPU worker nodes:
>
> ```bash
> oc label node <worker-node-1> node-role.kubernetes.io/gpu-worker=""
> oc label node <worker-node-2> node-role.kubernetes.io/gpu-worker=""
> ```
>
> Nodes can have both the `worker` and `gpu-worker` role labels simultaneously — the custom `gpu-worker` MCP takes priority over the default `worker` MCP.

> **Warning: triggers GPU worker node reboots.** The `iommu=pt` MachineConfig changes kernel boot arguments. Only nodes in the `gpu-worker` MachineConfigPool are rebooted.

```bash
oc apply -k 03-accelerator-operator-config/ocp-bare-metal-sriov/03-worker-gpu-rdma-config/
```

Verify:

```bash
oc get mcp gpu-worker -w    # Wait for MCP rollout (nodes reboot)
```

### Step 10: SR-IOV Operator Config

Configure the SR-IOV operator to run its config daemon on nodes with Mellanox SR-IOV-capable NICs.

> **Apply after** the SR-IOV operator CSV is ready (`oc get csv -n openshift-sriov-network-operator`).

```bash
oc apply -k 03-accelerator-operator-config/ocp-bare-metal-sriov/10-sriov-operator-config/
```

Verify:

```bash
oc get sriovoperatorconfig default -n openshift-sriov-network-operator
oc get pods -n openshift-sriov-network-operator
```

### Step 15: NVIDIA Network Operator

Deploy `NicClusterPolicy` with MOFED drivers and the RDMA shared device plugin.

The NicClusterPolicy sets `UNLOAD_THIRD_PARTY_RDMA_MODULES=true`, which tells MOFED to unload third-party RDMA kernel modules (Intel `irdma`, Broadcom `bnxt_re`, etc.) before loading its own drivers. This is required on nodes that have both Intel and Mellanox NICs — without it, the Intel `irdma` driver holds `ib_uverbs` and MOFED fails to start.

> **MOFED version**: The version in the manifest must match your NVIDIA Network Operator release. To find the correct version for your installed operator:
>
> ```bash
> oc get csv -n nvidia-network-operator -o jsonpath='{.items[0].metadata.annotations.alm-examples}' \
>   | python3 -c "import sys,json; [print(e['spec']['ofedDriver']['version']) for e in json.load(sys.stdin) if e['kind']=='NicClusterPolicy']"
> ```
>
> Update the `version` field in `nicclusterpolicy.yaml` if it doesn't match.

> **Apply before Step 14.** The SR-IOV config daemon waits for the `network.nvidia.com/operator.mofed.wait=false` node label, which is set when MOFED loads successfully. Step 14 (VF policies) requires the SR-IOV config daemon to be running.

```bash
oc apply -k 03-accelerator-operator-config/ocp-bare-metal-sriov/15-nvidia-network-operator/
```

Verify:

```bash
oc get nicclusterpolicy                                             # State should reach "ready"
oc get pods -n nvidia-network-operator -l app=mofed-ubuntu -w       # Wait for MOFED pods to be Running
oc get nodes -o custom-columns=NAME:.metadata.name,MOFED_WAIT:.metadata.labels.network\\.nvidia\\.com/operator\\.mofed\\.wait
```

### Step 14: SR-IOV VF Policies and Networks

Creates VFs on each ConnectX-6 port and defines the SR-IOV networks with VLAN tagging and whereabouts IPAM.

**What gets created:**

- `SriovNetworkNodePolicy` for port 1 — 8 VFs on `eno12399np0`, resource `sriov_vf_port1`
- `SriovNetworkNodePolicy` for port 2 — 8 VFs on `eno12409np1`, resource `sriov_vf_port2`
- `SriovNetwork` for port 1 — VLAN 103, `192.168.103.0/24`
- `SriovNetwork` for port 2 — VLAN 104, `192.168.104.0/24`

The `SriovNetwork` resources automatically create `NetworkAttachmentDefinition` resources in the target namespace.

> **Apply after Step 15.** The SR-IOV config daemon must be running before VF policies can be created. If you see `admission webhook denied the request`, wait for MOFED pods to be Running and the `mofed.wait` label to flip to `false`.

> **Before applying**, review the manifests and adjust:
> - PF interface names if different on your nodes
> - VLAN IDs to match your switch configuration
> - `networkNamespace` to match your workload namespace

> **Warning: triggers node drain and reboot.** Applying `SriovNetworkNodePolicy` creates VFs, which requires a node reboot.

```bash
oc apply -k 03-accelerator-operator-config/ocp-bare-metal-sriov/14-sriov-networks/
```

Verify:

```bash
oc get sriovnetworknodestates -n openshift-sriov-network-operator -o yaml  # VFs created
oc get net-attach-def -A                                                    # NADs auto-created
oc get node <worker> -o jsonpath='{.status.allocatable}' | jq .            # sriov_vf_port1, sriov_vf_port2 resources
```

### Step 20: GPU Readiness

Wait for MOFED drivers to be fully loaded before deploying the GPU ClusterPolicy.

```bash
oc apply -k 03-accelerator-operator-config/ocp-bare-metal-sriov/20-gpu-readiness/
```

```bash
oc logs job/wait-for-mofed-ready -n llm-d-setup -f
```

### Step 21: GPU Operands

Deploy the GPU Operator `ClusterPolicy` (drivers, device plugin, DCGM, nvidia-peermem, toolkit).

```bash
oc apply -k 03-accelerator-operator-config/ocp-bare-metal-sriov/21-gpu-operands/
```

Verify:

```bash
oc get clusterpolicy gpu-cluster-policy -o jsonpath='{.status.state}'
oc get pods -n nvidia-gpu-operator
oc get nodes -o custom-columns=NAME:.metadata.name,GPU:.status.allocatable.nvidia\\.com/gpu
```

## RDMA Validation

After all steps complete, proceed to [Chapter 04: Validate Cluster](../../04-validate-cluster-ready/) for RDMA connectivity and bandwidth tests.

## Problems Encountered and Solutions

### Intel `irdma` blocks MOFED

**Symptom**: MOFED pods crash with `rmmod: ERROR: Module ib_uverbs is in use by: irdma`.

**Cause**: Dell XE8640 (and similar servers) have Intel i40e/ice NICs alongside the Mellanox NICs. The Intel `irdma` driver auto-loads and grabs `ib_uverbs`, preventing MOFED from taking over RDMA.

**Fix**: Set `UNLOAD_THIRD_PARTY_RDMA_MODULES=true` in the NicClusterPolicy `ofedDriver.env` (already configured in Step 15). This tells the MOFED container to unload third-party RDMA modules (including `irdma`) before loading MOFED drivers.

### MOFED version mismatch

**Symptom**: MOFED pods stuck in `ImagePullBackOff` — the DOCA driver image tag doesn't exist.

**Cause**: The MOFED version in the NicClusterPolicy doesn't match what's available for your NVIDIA Network Operator release. The operator appends the OS version and architecture (e.g., `-rhel9.6-amd64`) to the version you provide. If the resulting tag doesn't exist in the registry, the pull fails.

**Fix**: Look up the correct version from your installed operator's CSV (see Step 15 instructions).

### SR-IOV config daemon not running

**Symptom**: `SriovNetworkNodePolicy` rejected by admission webhook — `no supported NIC is selected by the nicSelector`.

**Cause**: The SR-IOV config daemon pod only starts after MOFED loads (`mofed.wait=false`). If MOFED is failing, the config daemon never starts, and the webhook rejects VF policies.

**Fix**: Fix MOFED first (see above), then re-apply Step 14.

### `resourcePrefix` must be a valid FQDN

**Symptom**: NicClusterPolicy rejected with `resourcePrefix: Invalid value`.

**Cause**: In NVIDIA Network Operator v26.x+, the `resourcePrefix` field in `rdmaSharedDevicePlugin` config must be a valid FQDN (e.g., `nvidia.com`). Bare strings like `rdma` fail validation.

**Fix**: Use `"nvidia.com"` as the `resourcePrefix`. Pods then request `nvidia.com/roce` (or whatever `resourceName` you set).
