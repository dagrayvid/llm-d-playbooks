# Cluster Notes — BMAS-001 (Dell B200 / NVIDIA B200)

## Cluster Overview

- **Platform**: Bare-metal OpenShift (RoCE networking)
- **Nodes**:
  - `dell-b200-1.bmas-001.lab.rdu2.dc.redhat.com`
  - `dell-b200-2.bmas-001.lab.rdu2.dc.redhat.com`
- **GPUs**: 8x NVIDIA B200 per node
- **NICs**: 10x Mellanox ConnectX-7 (mlx5) per node, NDR200 (400 Gb/s per port)
- **Management**: Dell iDRAC (MX750c chassis)
- **CPUs**: 2x Intel Xeon Platinum 8570 (56 cores each, 2.10 GHz)

## BIOS Settings (iDRAC)

### Current settings (relevant)

| Setting | Location | Value | Notes |
|---------|----------|-------|-------|
| SR-IOV Global Enable | Integrated Devices | **Enabled** | Causes ACS to be enabled on all PCIe bridges at POST |
| Virtualization Technology | Processor Settings | Enabled | Required for IOMMU (VT-d) |
| Kernel DMA Protection | Processor Settings | Disabled | |
| Sub NUMA Cluster | Processor Settings | Disabled | |
| x2APIC Mode | Processor Settings | Enabled | |

### Unexplored BIOS alternatives

1. **Disable SR-IOV Global Enable** — Would likely disable ACS at the firmware level, removing the need for the systemd `setpci` service. Trade-off: SR-IOV VFs would be unavailable. Since the current macvlan approach doesn't use VFs, this is a viable option. Not yet tested because the systemd approach was simpler to deploy without iDRAC access/reboot coordination.

2. **Kernel DMA Protection** — Currently disabled. If enabled, it activates Intel DMA Remapping (DMAR) which could interfere with `iommu=pt` passthrough mode. Should remain disabled for GPUDirect RDMA.

3. **Sub NUMA Cluster (SNC)** — Currently disabled. If enabled, splits each NUMA node into sub-nodes, which could affect GPU-NIC affinity detection by NCCL. The current 2-NUMA topology (NUMA 0 = GPUs 0-3 + NICs 0-6, NUMA 1 = GPUs 4-7 + NICs 7-17) is well-understood. Enabling SNC would need re-evaluation of topology assumptions.

### Settings not available in this BIOS

- **PCI ACS control** — No dedicated ACS toggle exists in this Dell BIOS. ACS is implicitly controlled by SR-IOV Global Enable.
- **Per-device SR-IOV** — SR-IOV is all-or-nothing at the system level; cannot enable it for NICs but disable for GPU PCIe bridges.

## Network Topology

### L3 Routed RoCE Fabric (Rail-Based)

No VLANs — pure L3 routed. Each PF is assigned to a rail (0–9), each rail gets its own `/16`, and the node's hostId determines the third octet.

```
subnet:  172.<16 + railId>.<hostId>.0/24
hostIp:  172.<16 + railId>.<hostId>.1
gateway: 172.<16 + railId>.<hostId>.254
```

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

- `ens33f0np0` exists on the nodes but is not cabled/used for RoCE (11 PFs total, 10 mapped)
- Static routes per interface: `172.<16+rail>.0.0/16` (rail-specific) and `172.16.0.0/12` (ECMP fallback)

### Networking Approach

Using **RDMA Shared Device Plugin + macvlan CNI + NV-IPAM** (not SR-IOV VFs).
This approach is simpler, more robust, and topology-agnostic — applications (NCCL/UCX) handle GPU-NIC affinity themselves.

## Problems Encountered and Solutions

### 1. SR-IOV VF approach abandoned

**Problem**: SR-IOV with VFs was complex, required firmware configuration for VF counts, and had topology/scheduling constraints.

**Solution**: Switched to RDMA Shared Device Plugin + macvlan. Each pod gets macvlan sub-interfaces on the physical PFs with shared RDMA device access. No VFs, no firmware changes, no reboots for NIC config.

### 2. NicClusterPolicy wiped by partial `oc apply`

**Problem**: Applying a partial `NicClusterPolicy` manifest (e.g., just `rdmaSharedDevicePlugin` and `nvIpam`) via `oc apply` caused strategic merge patch to **remove** unspecified sections like `ofedDriver`, killing MOFED driver pods.

**Solution**: Consolidated all `NicClusterPolicy` fields into a single template in the step 14 job. The job constructs the full resource (including `ofedDriver`, `rdmaSharedDevicePlugin`, `nvIpam`) and uses `oc patch --type=merge` for updates.

### 3. Python 3.6 in ose-cli image

**Problem**: The `ose-cli` container image (used by configuration Jobs) ships Python 3.6, which lacks `subprocess.run(capture_output=True)` and doesn't have `pyyaml` installed.

**Solution**: Rewrote scripts to use `json.dumps()` instead of `yaml.dump()` (JSON is valid YAML) and used `subprocess.run(stdout=PIPE, stderr=PIPE)` instead of `capture_output=True`.

### 4. Macvlan MTU validation failure

**Problem**: MacvlanNetwork resources were created with MTU 9000, but the host PFs were at MTU 1500. The macvlan CNI plugin validates that the requested MTU does not exceed the master interface MTU, causing pod creation to fail with `invalid MTU 9000, must be [0, master MTU(1500)]`.

**Solution**: Temporarily set MTU to 1500 in the macvlan job config. For production, need to set PF MTUs to 9000 first (via MachineConfig/NM dispatcher script), then use MTU 9000 in macvlan config. The PF NICs do accept `ip link set mtu 9000` — the hardware supports it.

**Order of operations for jumbo (9000):**

1. **Raise MTU on every RoCE PF on every worker** (must be **before** pods use macvlan with `mtu: 9000`). The CNI checks the **live** host interface, not a saved OpenShift object.
2. Set **`MTU=9000`** on the `configure-macvlan-networks` Job env and re-run the job so NADs contain `"mtu": 9000`.
3. Recreate pods.

**Quick (non-persistent — lost on reboot or some NM events):** On each node, as root on the host network namespace:

```bash
# Example: adjust to your PF names (see network-mapping / ip link)
for d in ens31f0np0 ens32f0np0 ens34f0np0 ens35f0np0 ens36f0np0 ens37f0np0 ens38f0np0 ens40f0np0 ens41f0np0 ens42f0np0; do
  ip link set dev "$d" mtu 9000 2>/dev/null || true
done
```

Or one-shot via debug (replace node name):

```bash
oc debug node/<worker-node-name> -- chroot /host bash -c \
  'for d in /sys/class/net/ens*f0np0; do ip link set dev "${d##*/}" mtu 9000; done'
```

Verify: `ip link show ens40f0np0` → `mtu 9000`.

**Persistent:** MachineConfig `98-worker-roce-pf-mtu` installs a systemd oneshot service that sets MTU 9000 on all mlx5_core PFs at boot. A NetworkManager dispatcher approach was tried first but failed because NM doesn't manage the PFs (no NM connection profiles), so dispatcher events don't fire for them. The systemd service runs after `NetworkManager.service` and iterates all `ens*` interfaces with `mlx5_core` driver. Match VLAN/subnet layout so switches also carry **MTU 9000** end-to-end.

### 5. GPUDirect RDMA — `Couldn't allocate MR with error=12` (ENOMEM)

**Problem**: `ib_write_bw --use_cuda` failed with `Couldn't allocate MR with error=12` when trying to register GPU memory for RDMA.

**Root cause**: Two combined issues:
1. **ACS (Access Control Services)** was enabled on PCIe bridges, redirecting P2P DMA through the root complex instead of allowing direct GPU↔NIC transfers
2. **memlock ulimit** was 8192 KB (8MB), below the GPU buffer size being registered

**Solution**: Disabling ACS was the primary fix. ACS was the actual blocker — once disabled, MR registration succeeded even with the 8192 KB memlock limit in some cases. However, `privileged: true` or a `ContainerRuntimeConfig` with unlimited memlock is still needed for reliable operation with larger buffers.

### 6. GPUDirect RDMA — `Failed to modify QP to RTR` / `IBV_WC_LOC_PROT_ERR`

**Problem**: After resolving the MR allocation error, `ib_write_bw --use_cuda` failed during data transfer with syndrome `0x51` (`IBV_WC_LOC_PROT_ERR`), meaning the NIC couldn't DMA to/from GPU memory.

**Root cause**: Again ACS. The PCIe bridges between GPUs and NICs had ACS enabled (`ReqRedir+`, `CmpltRedir+`), forcing P2P transactions through the root complex where IOMMU (in full translation mode, not passthrough) blocked them.

**Solution**: Disable ACS on all PCIe bridges. Confirmed via:
```bash
# Temporary (non-persistent) fix:
for bdf in $(lspci -D | grep "PCI bridge" | awk '{print $1}'); do
  val=$(setpci -s "$bdf" ECAP_ACS+6.w 2>/dev/null) || continue
  [ "$val" != "0000" ] && setpci -s "$bdf" ECAP_ACS+6.w=0000
done
```

**Permanent fix** in playbook: MachineConfig `99-worker-gpu-rdma` with kernel arguments `pci=noacs` and `iommu=pt`, plus MachineConfig `99-worker-disable-pcie-acs` with a systemd oneshot service.

**Why both?** `pci=noacs` prevents the kernel from enabling ACS during PCI enumeration, but does not clear ACS that firmware/BIOS enables during POST. On Dell PowerEdge servers (and many enterprise servers), the BIOS enables ACS on all PCIe bridges when SR-IOV Global Enable is on — even if no VFs are configured. The systemd service runs `setpci` at boot to clear firmware-set ACS.

**Alternative BIOS fix:** Disabling "SR-IOV Global Enable" in iDRAC BIOS (Integrated Devices) would likely disable ACS at the firmware level, avoiding the need for the systemd service. However, this also prevents SR-IOV VFs from ever being created. Since the macvlan approach doesn't use VFs, disabling SR-IOV in BIOS is a valid option. If SR-IOV VFs are needed later (even on bare-metal), the systemd service approach is the only way to have both SR-IOV and ACS disabled.

### 7. IOMMU in full translation mode

**Problem**: `journalctl` on host showed `iommu: Default domain type: Translated`, meaning IOMMU was doing full address translation rather than passthrough. When P2P DMA did reach the root complex (due to ACS), the IOMMU blocked it.

**Solution**: `iommu=pt` kernel argument sets IOMMU to passthrough mode. Combined with `pci=noacs`, this ensures P2P DMA works regardless of PCIe topology. Both are set via MachineConfig `99-worker-gpu-rdma`.

### 8. memlock ulimit not raised by IPC_LOCK capability alone

**Problem**: Test pods had `IPC_LOCK` capability, but `ulimit -l` was still 8192 KB. The capability allows calling `mlock()` but doesn't change the rlimit. CRI-O sets the hard limit at container creation time.

**Solution**: `ContainerRuntimeConfig` (`worker-rdma-memlock`) sets `defaultUlimits` for memlock to `-1` (unlimited) on all worker nodes. This is applied alongside the MachineConfig in step 03 of the playbook. Pods still need `IPC_LOCK` capability (or `privileged: true`) to actually use mlock.

### 9. In-pod GPU-NIC topology mapping is non-trivial

**Problem**: Inside a pod, you can't directly see which macvlan interface (net0, net1, ...) maps to which host PF and which GPU it's topologically closest to. The sysfs paths for PF names aren't visible in the pod's network namespace.

**Solution**: Created diagnostic scripts (`pod-rdma-macvlan-diag.sh` + `run-diag-macvlan.sh`) that:
1. Fetch the pod's `k8s.v1.cni.cncf.io/network-status` annotation (maps net* → NAD → PF)
2. Get HCA→PCI→PF mapping from the host (via MOFED driver pod)
3. Use `nvidia-smi topo -m` inside the pod to map GPU→HCA affinity
4. Combine all three to produce a full GPU→HCA→PF→macvlan→IP mapping table

## Validated Performance

| Test | GPU→NIC | Subnets | MTU | QPs | Bandwidth |
|------|---------|---------|-----|-----|-----------|
| Same-rail GPUDirect | GPU0→mlx5_0 (PIX) | same | 1500 | 1 | ~370 Gb/s |
| Same-rail GPUDirect | GPU0→mlx5_0 (PIX) | same | 9000 | 1 | ~388 Gb/s |
| Cross-rail (wrong NIC) | GPU0→mlx5_0 (PIX) ↔ GPU1→mlx5_1 (NODE) | different | 9000 | 8 | ~290 Gb/s |
| **Cross-rail (correct)** | **GPU0→mlx5_0 (PIX) ↔ GPU1→mlx5_2 (PIX)** | **different + SBR** | **9000** | **8** | **392 Gb/s** |
| Host memory RDMA | N/A | same | 1500 | 1 | ~370 Gb/s |

Key findings:
- **PIX GPU-NIC alignment is critical** — NODE relationship costs ~100 Gb/s (~290 vs ~392 Gb/s)
- **Switch inter-VLAN routing adds zero penalty** — cross-rail with correct PIX alignment matches same-rail performance
- **SBR is mandatory** for cross-subnet RDMA — without it, RoCE packets can't reach the gateway and connections fail
- **Jumbo frames (MTU 9000)** improve throughput by ~5% (370→388 Gb/s)
- PF MTU must be set to 9000 on the host **before** macvlan interfaces are created (macvlan CNI validates against master MTU)

### GPU-NIC PIX Topology (Dell B200 / MX750c)

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

### Source-Based Routing (SBR)

Required for cross-rail RDMA when each PF is on a separate subnet/VLAN. Without SBR, the kernel routes cross-subnet traffic via the local macvlan on the destination subnet instead of through the gateway — RoCE packets never leave the correct physical port.

SBR creates per-interface routing tables that force packets to exit through the interface whose IP they originated from:
```bash
# For each macvlan interface:
ip rule add from <interface_ip> table <table_id> priority <table_id>
ip route add <subnet> dev <iface> table <table_id> scope link
ip route add default via <gateway> dev <iface> table <table_id> onlink
```

Implementation options:
- Chained SBR CNI plugin (used on IBM Cloud with custom sbr-custom DaemonSet)
- Init container in workload pods
- Pod entrypoint script

## Playbook Prerequisites for GPUDirect RDMA

Step `03-worker-gpu-rdma-config` applies:

| Resource | Purpose |
|----------|---------|
| MachineConfig `99-worker-gpu-rdma` | `iommu=pt` + `pci=noacs` kernel args |
| MachineConfig `99-worker-disable-pcie-acs` | Systemd service to clear firmware-set ACS at boot |
| MachineConfig `98-worker-roce-pf-mtu` | Systemd service to set MTU 9000 on all ConnectX PFs at boot |
| ContainerRuntimeConfig `worker-rdma-memlock` | Unlimited memlock for all containers on workers |

All trigger a MachineConfigPool update (node reboot). Pause MCPs before applying to batch into a single rollout.

### Combined master+worker nodes

This cluster has dell-b200-2 as both `control-plane,master,worker`. Nodes with master role belong to the `master` MCP, so worker-targeted MachineConfigs don't apply to them. The `overlays/master/` directory contains master-role copies of all configs:

```bash
# Worker nodes (default)
oc apply -k 05-ocp-accelerator-operators/03-worker-gpu-rdma-config/base/

# Master nodes that also run GPU workloads (opt-in)
oc apply -k 05-ocp-accelerator-operators/03-worker-gpu-rdma-config/overlays/master/
```

### GID index inconsistency

RDMA GID table indices vary across nodes and even across devices within a node:
- Host-level IPs on PFs (e.g., manual IP on `ens40f0np0`) add extra GID entries, shifting indices
- Different nodes may have different numbers of system interfaces, changing GID table layout
- On one node: 9/10 devices at GID[3], mlx5_0 at GID[5]. On the other: all devices at GID[5]

This is a non-issue in practice:
- NCCL auto-detects GIDs by scanning the table (no index needed)
- `ib_write_bw` works without `-x` (auto-selects valid RoCE v2 GID per device)
- `NCCL_IB_GID_INDEX` should NOT be set as a global constant across the cluster
