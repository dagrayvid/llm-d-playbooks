# Case Study: Bare-Metal A100 with InfiniBand (HDR)

## Environment

- **Platform**: Bare-metal OpenShift 4.22
- **GPU nodes**: 4 workers, labeled `node-role.kubernetes.io/a100-gpu`
- **GPUs per node**: 8x NVIDIA A100 SXM4
- **NICs per node**: 8x Mellanox ConnectX-6 (MT28908 / MT4123), InfiniBand HDR (200 Gbps per port)
- **CPUs per node**: 2 sockets, 2 NUMA nodes
- **RDMA Transport**: InfiniBand
- **Subnet Manager**: Switch-managed (single fabric)
- **CNI Strategy**: RDMA shared device plugin on PFs (no SR-IOV, no macvlan, no SBR)

## Key Characteristics

- NICs are **physical functions** (PFs) directly visible to the OS
- Uses **RDMA shared device plugin** directly on PFs — no VFs, no macvlan, no SBR
- The IB **subnet manager runs on the switch** — no need for a host-side SM
- All 8 HCAs on each node connect to the **same IB fabric** (single SM lid)
- Uses a **custom MachineConfigPool** (`a100-gpu`) to target GPU workers without rebooting control-plane nodes

## Network Topology

### IB Fabric

All 32 HCAs (8 per node × 4 nodes) connect to a single IB fabric with one switch-managed subnet manager. IPoIB interfaces use kernel-assigned names in the format `ibpXsY`, consistent across nodes with identical PCI topology.

### GPU-NIC PCIe Topology

The PCIe topology is **identical across all 4 nodes**. Each node has 4 PCIe switches, 2 per NUMA node. Each switch hosts 2 GPUs and 2 IB NICs in a **PXB** (same PCIe switch, different downstream ports) relationship — optimal for GPUDirect RDMA.

```
NUMA 0
├── Switch 01:00.0
│   ├── GPU 0 (A100 SXM4)
│   ├── GPU 1 (A100 SXM4)
│   ├── mlx5_2 (ibp14s0, 200G IB)
│   └── mlx5_3 (ibp17s0, 200G IB)
├── Switch 3f:00.0
│   ├── GPU 2 (A100 SXM4)
│   ├── GPU 3 (A100 SXM4)
│   ├── mlx5_0 (ibp82s0, 200G IB)
│   └── mlx5_1 (ibp83s0, 200G IB)

NUMA 1
├── Switch 7e:00.0
│   ├── GPU 4 (A100 SXM4)
│   ├── GPU 5 (A100 SXM4)
│   ├── mlx5_6 (ibp139s0, 200G IB)
│   └── mlx5_7 (ibp142s0, 200G IB)
├── Switch ba:00.0
│   ├── GPU 6 (A100 SXM4)
│   ├── GPU 7 (A100 SXM4)
│   ├── mlx5_4 (ibp199s0, 200G IB)
│   └── mlx5_5 (ibp202s0, 200G IB)
```

### GPU-NIC PXB Mapping

| PCIe Switch | NUMA | GPUs | NICs (mlx5) | IPoIB Interfaces |
|-------------|------|------|-------------|------------------|
| 01:00.0 | 0 | GPU 0, GPU 1 | mlx5_2, mlx5_3 | ibp14s0, ibp17s0 |
| 3f:00.0 | 0 | GPU 2, GPU 3 | mlx5_0, mlx5_1 | ibp82s0, ibp83s0 |
| 7e:00.0 | 1 | GPU 4, GPU 5 | mlx5_6, mlx5_7 | ibp139s0, ibp142s0 |
| ba:00.0 | 1 | GPU 6, GPU 7 | mlx5_4, mlx5_5 | ibp199s0, ibp202s0 |

Note: mlx5 device numbering is not sequential with PCIe order — `mlx5_0`/`mlx5_1` are on the second switch of NUMA 0, not the first.


## Prerequisites

- OpenShift Container Platform >= 4.19 (bare metal)
- Cluster-admin access via `oc` CLI
- Mellanox ConnectX-6 NICs with InfiniBand HDR connectivity
- IB fabric with a running subnet manager (switch-managed or host-based)
- All IB ports in `Active` / `LinkUp` state (verify with `ibstat` from a debug pod)
- GPU worker nodes labeled with `node-role.kubernetes.io/a100-gpu`

## Steps

Apply each step in order. Steps are numbered to match other case studies for cross-reference; gaps are intentional where steps don't apply to this environment.

### Step 00: Discover GPUs & NICs

Run the hardware probe to identify NIC types, GPU models, and NUMA topology.

```bash
./03-accelerator-operator-config/common/00-discover-gpus-nics/discover-gpu-nic-topology.sh
```

This outputs per-node JSON to `/tmp/gpu-nic-probe/` with GPU models, NIC PCI addresses, link types, and NUMA groupings. Review the output to confirm your hardware matches the topology described above.

### Step 01: Operator Subscriptions

Install NFD, NVIDIA GPU Operator, and NVIDIA Network Operator.

```bash
oc apply -k 03-accelerator-operator-config/ocp-bare-metal-infiniband/01-operator-subscriptions/
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
oc apply -k 03-accelerator-operator-config/ocp-bare-metal-infiniband/02-nfd-operands/
```

Verify NFD labels are applied to GPU nodes:

```bash
oc get nodes -l feature.node.kubernetes.io/pci-10de.present -o name
oc get nodes -l feature.node.kubernetes.io/pci-15b3.present -o name
```

### Step 03: Worker GPU/RDMA Config

> **Warning: triggers GPU worker node reboots.** MachineConfig changes kernel boot arguments. Only nodes in the `a100-gpu` MachineConfigPool are rebooted — control-plane nodes are not affected.

This step assumes the `a100-gpu` MachineConfigPool already exists. Verify:

```bash
oc get mcp a100-gpu
```

If it doesn't exist, create it — the MCP selects nodes by role label and tells the MCO which MachineConfigs to apply to them:

```bash
oc apply -f - <<'EOF'
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfigPool
metadata:
  name: a100-gpu
spec:
  machineConfigSelector:
    matchExpressions:
      - key: machineconfiguration.openshift.io/role
        operator: In
        values: [worker, a100-gpu]
  nodeSelector:
    matchLabels:
      node-role.kubernetes.io/a100-gpu: ""
EOF
```

The `matchExpressions` ensures these nodes inherit base `worker` MachineConfigs while also receiving `a100-gpu`-targeted ones. This prevents control-plane nodes (which also carry the `worker` role) from being rebooted by GPU/RDMA config changes.

This step applies three MachineConfigs:

1. **`99-a100-gpu-rdma`** — `iommu=pt` (IOMMU passthrough for GPUDirect RDMA) + `pci=noacs` (prevent kernel from enabling PCIe ACS). Without `pci=noacs`, the kernel can re-enable ACS on PCI bridges during driver loads or rescans, undoing the work of the ACS disable service.

2. **`99-a100-gpu-disable-acs-p2p-redirect`** — systemd oneshot service that clears ACS **P2P Redirect** bits (ReqRedir + CmpltRedir) on PCI bridges at boot. These two bits are what redirect peer-to-peer transactions upstream through the root complex instead of allowing direct GPU-to-NIC transfers within the PCIe switch. The script is surgical — it only clears bits 2+3 (mask `0x0c`) and preserves SrcValid, UpstreamFwd, and other ACS bits that don't affect P2P. Runs `Before=nvidia-driver.service` to ensure ACS is cleared before GPUDirect RDMA is used.

3. **`99-a100-gpu-crio-memlock`** — CRI-O config setting `memlock=-1:-1` (unlimited). Required for RDMA memory registration — `ibv_reg_mr()` pins memory and fails with `ENOMEM` if memlock is capped.

#### Pause, apply, unpause (single reboot)

By default, the MCO rolls out each MachineConfig change one at a time, rebooting nodes between each. To apply all three MachineConfigs in a **single reboot**, pause the MachineConfigPool first:

```bash
oc patch mcp a100-gpu --type merge -p '{"spec":{"paused":true}}'
```

Apply the MachineConfigs:

```bash
oc apply -k 03-accelerator-operator-config/ocp-bare-metal-infiniband/03-worker-gpu-rdma-config/
```

Verify the MachineConfigs were created:

```bash
oc get machineconfigs | grep a100-gpu
```

You should see `99-a100-gpu-rdma`, `99-a100-gpu-disable-acs-p2p-redirect`, and `99-a100-gpu-crio-memlock`.

Now unpause the pool to trigger a single rolling reboot with all changes applied:

```bash
oc patch mcp a100-gpu --type merge -p '{"spec":{"paused":false}}'
```

Watch the rollout:

```bash
oc get mcp a100-gpu -w
```

The rollout is complete when `UPDATED=True`, `UPDATING=False`, and `DEGRADED=False`. Each node reboots once with all three MachineConfigs applied.

#### Verification

After reboot, verify kernel arguments on a GPU worker:

```bash
oc debug node/a100-01 -- chroot /host cat /proc/cmdline | tr ' ' '\n' | grep -E 'iommu|noacs'
```

Expected output:

```
iommu=pt
pci=noacs
```

Verify ACS P2P Redirect is cleared on PCI bridges in the GPU-NIC path:

```bash
oc debug node/a100-01 -- chroot /host bash -c '
for dev in /sys/bus/pci/devices/*/; do
  bdf=$(basename "$dev")
  class=$(cat "$dev/class" 2>/dev/null)
  if [[ "$class" == 0x0604* ]]; then
    acs=$(setpci -s "$bdf" ECAP_ACS+6.w 2>/dev/null) || continue
    val=$((16#${acs}))
    if (( val & 0x0c )); then
      echo "$bdf ACS=0x$acs ReqRedir=$((val>>2 & 1)) CmpltRedir=$((val>>3 & 1))"
    fi
  fi
done
echo "ACS P2P redirect check complete"'
```

Any bridges listed still have P2P redirect enabled. Cross-reference the BDF with the PCIe topology (Step 00) — only bridges on the path between GPUs and NICs matter for GPUDirect RDMA. Bridges on unused switch downstream ports (e.g., `XX:0c.0`) can be safely ignored.

Verify memlock:

```bash
oc debug node/a100-01 -- chroot /host bash -c 'ulimit -l'
```

Expected output: `unlimited`

#### Adapting Step 03 for Your Environment

- **Different GPU role label**: Update the `machineconfiguration.openshift.io/role` label in all MachineConfig YAMLs to match your MachineConfigPool name.
- **GPU nodes on the default `worker` role (no custom MCP)**: Change the `machineconfiguration.openshift.io/role` label in all MachineConfigs to `worker`. Be aware that this will reboot **all** workers, including any without GPUs.
- **ACS disable not needed**: If your BIOS does not enable ACS on PCIe bridges (check with `setpci -s <bridge-bdf> ECAP_ACS+6.w`), you can remove `machineconfig-disable-acs.yaml` from the kustomization. You still need `pci=noacs` to prevent the kernel from enabling ACS.

### Step 15: NVIDIA Network Operator (NicClusterPolicy)

Deploys the `NicClusterPolicy` with:
- **MOFED drivers** — containerized Mellanox OFED drivers for InfiniBand
- **RDMA shared device plugin** — exposes IB HCAs as Kubernetes extended resources (`rdma/ib`)

The device plugin selects HCAs by vendor (`15b3`) and device ID (`101b` for ConnectX-6). Change the `deviceIDs` selector if your NICs are a different model (e.g., `1017` for ConnectX-5 Ex, `1021` for ConnectX-7).

**Before applying**, verify the MOFED driver version in `nicclusterpolicy.yaml` matches your NVIDIA Network Operator version:

```bash
oc get csv -n nvidia-network-operator -o jsonpath='{.items[0].metadata.name}'
```

If the operator version doesn't match the `ofedDriver.version` in the manifest, update the manifest before applying. Check the [NVIDIA Network Operator release notes](https://docs.nvidia.com/networking/display/kubernetes2610) for the correct MOFED image tag.

```bash
oc apply -k 03-accelerator-operator-config/ocp-bare-metal-infiniband/15-nvidia-network-operator/
```

Wait for MOFED driver pods to come up on all GPU nodes:

```bash
oc get pods -n nvidia-network-operator -l nvidia.com/ofed-driver -w
```

Verify MOFED is loaded:

```bash
oc exec -n nvidia-network-operator \
  $(oc get pods -n nvidia-network-operator -l nvidia.com/ofed-driver -o jsonpath='{.items[0].metadata.name}') \
  -- ofed_info -s
```

Verify RDMA shared device plugin pods are running:

```bash
oc get pods -n nvidia-network-operator -l app=rdma-shared-dp
```

Verify RDMA resources are advertised on GPU nodes:

```bash
oc get nodes -l node-role.kubernetes.io/a100-gpu -o custom-columns=NAME:.metadata.name,RDMA:.status.allocatable.rdma/ib
```

Each GPU node should report `63` allocatable RDMA devices.

### Step 20: GPU Readiness

Wait for MOFED drivers to be ready before the GPU Operator starts loading its drivers.

```bash
oc apply -k 03-accelerator-operator-config/ocp-bare-metal-infiniband/20-gpu-readiness/
```

Monitor the readiness jobs:

```bash
oc logs job/wait-for-network-operator -n llm-d-setup -f
oc logs job/wait-for-mofed-ready -n llm-d-setup -f
```

### Step 21: GPU Operands

Deploy the GPU Operator ClusterPolicy. This installs GPU drivers, device plugin, DCGM, GDRCopy, and other GPU operator components.

```bash
oc apply -k 03-accelerator-operator-config/ocp-bare-metal-infiniband/21-gpu-operands/
```

Wait for the ClusterPolicy to reach `ready` state:

```bash
oc get clusterpolicy gpu-cluster-policy -w
```

Verify GPUs are available as Kubernetes resources:

```bash
oc get nodes -l node-role.kubernetes.io/a100-gpu \
  -o custom-columns=NAME:.metadata.name,GPU:.status.allocatable.nvidia\\.com/gpu
```

Each GPU node should report `8` GPUs.

## RDMA Validation

After all steps complete, proceed to [Chapter 04: Validate Cluster](../../04-validate-cluster-ready/) for RDMA connectivity and bandwidth tests.

For InfiniBand, RDMA validation tests use IB verbs directly (e.g., `ib_write_bw`, `ib_read_bw`) rather than RoCE-specific tooling. Expected bandwidth for A100 + ConnectX-6 HDR with PXB alignment is ~24 GB/s (~192 Gbps) per HCA.

## Validated Performance

> **TODO**: Fill in after running RDMA validation tests on this cluster.

| Test | GPU-NIC Relationship | Bandwidth |
|------|---------------------|-----------|
| Same-switch GPUDirect | PXB | TBD |
| Cross-switch (same NUMA) | NODE | TBD |
| Cross-NUMA GPUDirect | SYS | TBD |
| Multi-rail aggregate | PXB × 8 | TBD |

## Problems Encountered and Solutions

> **TODO**: Document issues encountered during bring-up.

## Appendix: Validated Hardware Details

Reference data from the cluster used to develop this case study.

### IB Port Status

All 8 HCAs on each node report identical status (verified via `ibstat`):

| Field | Value |
|-------|-------|
| CA type | MT4123 (ConnectX-6) |
| Firmware | 20.40.1000 |
| State | Active |
| Physical state | LinkUp |
| Rate | 200 (HDR) |
| Link layer | InfiniBand |
| SM lid | 45 |

### Node Inventory

| Node | Role | GPUs | HCAs |
|------|------|------|------|
| `a100-01` | GPU worker | 8x A100 SXM4 | 8x ConnectX-6 (MT28908) |
| `a100-02` | GPU worker | 8x A100 SXM4 | 8x ConnectX-6 (MT28908) |
| `a100-03` | GPU worker | 8x A100 SXM4 | 8x ConnectX-6 (MT28908) |
| `a100-08` | GPU worker | 8x A100 SXM4 | 8x ConnectX-6 (MT28908) |
| `master0`–`master2` | Control plane | — | — |
