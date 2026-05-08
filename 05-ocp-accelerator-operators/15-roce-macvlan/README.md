# RoCE Macvlan + RDMA Shared Device Plugin

> **WARNING:** We observed consistent RoCE failures when multiple pods with macvlan
> interfaces share the same node. See [Macvlan RoCE Multi-Pod Observations](#macvlan-roce-multi-pod-observations)
> below. We are switching to SR-IOV (Step 13) for P/D deployments while investigation
> continues.

Configures RoCE networking using macvlan CNI and the RDMA Shared Device Plugin,
as an alternative to SR-IOV. Every pod sees every physical NIC and its RDMA device;
NCCL/UCX handles topological GPU-NIC pairing automatically.

## How It Works

| Component | Role |
|-----------|------|
| `rdmaSharedDevicePlugin` | Exposes one pooled resource `rdma/shared_roce` for all RoCE PFs (configured in step 14) |
| `nvIpam` | NVIDIA IPAM plugin allocates IPs from per-PF pools (configured in step 14) |
| `IPPool` | One per PF, defines the subnet for macvlan IP allocation (this step) |
| `NetworkAttachmentDefinition` | One per PF in `openshift-multus` (cluster-wide) — macvlan + NV-IPAM + optional `sbr-custom` (this step) |

## Prerequisites

- Step 12 (NIC discovery) has run
- Step 14 (NicClusterPolicy with OFED + rdmaSharedDevicePlugin + nvIpam) has been applied
- `network-mapping` ConfigMap exists in `llm-d-setup` namespace with PF-to-subnet mappings

## What This Step Creates

The `configure-macvlan-networks` Job reads the `network-mapping` ConfigMap and creates:

1. **IPPool** per PF — `perNodeBlockSize: 20` supports up to 12 nodes per `/24` subnet (name `pool-<pfName>`, unchanged)
2. **NetworkAttachmentDefinition** per PF in **`openshift-multus`** — name **`<NAD_NAME_PREFIX>-<n>`** (job default **`llmd-roce-net-<n>`** so it does not overwrite other `roce-net-*` NADs already in the cluster). Override env **`NAD_NAME_PREFIX`** (e.g. `roce-net`) when you intend to own that name set. The macvlan **`master`** is still the real PF (e.g. `ens40f0np0`); only the Multus **attachment name** is abstract.

### NAD numbering (`<prefix>-<n>`)

- **Optional `roceIndex`** (integer) on **every** PF in `mapping.json`: sets `<n>` for that PF. Values must be unique.
- **Omit `roceIndex` on all PFs**: `<n>` is `0 … N-1` in **sorted PF name** order (deterministic, not GPU-aware).
- Do not mix some PFs with `roceIndex` and some without (the job will error).

Pods reference networks by NAD name, e.g. `{"name": "llmd-roce-net-3", "namespace": "openshift-multus"}` (match your chosen prefix).

### GPU index (CUDA / `nvidia-smi`) vs `roceIndex`

**What “GPU 0, GPU 1, …” means:** On a node, the driver assigns each physical GPU an integer **CUDA device index** `0 … N-1`. That is the same ordering you see in:

- `nvidia-smi -L` (lines “GPU 0:”, “GPU 1:”, …)
- `nvidia-smi --query-gpu=index,name,pci.bus_id --format=csv`
- Inside containers, `CUDA_VISIBLE_DEVICES` and the device plugin use this **canonical** order (by default **PCI bus order**, unless you change env vars like `CUDA_DEVICE_ORDER`).

So **`nvidia-smi` is the practical source of truth** for “which index is which GPU” on that machine.

**How that relates to `roceIndex`:** `roceIndex` only sets **`<n>`** in **`$NAD_NAME_PREFIX-<n>`**; it does **not** auto-bind a PF to a GPU. If you want **`<n>` to line up with CUDA GPU index**, you still decide **which RoCE PF pairs with which GPU** using topology (NUMA, PCIe proximity). Common inputs:

- `nvidia-smi topo -m` — GPU–GPU and GPU–NIC distance (on the node)
- `./00-discover-gpus-nics/discover-gpu-nic-topology.sh` — NUMA grouping of GPUs and NICs

Example: if **GPU 2** (per `nvidia-smi -L`) is on the same NUMA node as **`ens40f0np0`**, you might set **`"roceIndex": 2`** on that PF so **`llmd-roce-net-2`** (with the default prefix) is “the RoCE network we associate with GPU 2” in your docs and automation. If you have **more NICs than GPUs**, some indices are only “NIC labels,” not 1:1 with GPUs.

You do **not** need `roceIndex` to match GPU indices; **sorted PF names** (`llmd-roce-net-0…` auto) is fine if you only want stable, abstract names.

### MTU (macvlan vs host PF)

The job env **`MTU`** (default **`1500`**) is written into each NAD’s macvlan stanza. It **must not exceed** the master PF’s MTU on the node (`invalid MTU 9000, must be [0, master MTU(1500)]` if the PF is still at 1500). After you raise RoCE PF MTU on the hosts (e.g. 9000 for jumbo), set **`MTU=9000`** on the Job and re-run. See also `docs/baremetal-ocp-roce-b200-notes.md`.

## Manual Apply

```bash
# Ensure network-mapping ConfigMap exists
oc get configmap network-mapping -n llm-d-setup

# Apply the Job
oc apply -k base/

# Watch the Job
oc logs -f job/configure-macvlan-networks -n nvidia-network-operator

# Verify NADs were created (cluster-wide Multus namespace)
oc get net-attach-def -n openshift-multus
```

## Validation

Deploy test pods from `validation/rdma-macvlan-test-pod.yaml`:

```bash
oc apply -f ../validation/rdma-macvlan-test-pod.yaml
```

Inside a test pod:

```bash
# Check macvlan interfaces got IPs
ip addr show | grep -A2 'net[0-9]'

# Check RDMA devices are visible
rdma link show

# Run RDMA bandwidth test between pods
# Pod 0:
ib_write_bw -d <device> --report_gbits
# Pod 1:
ib_write_bw -d <device> <pod0-ip> --report_gbits
```

---

## Macvlan RoCE Multi-Pod Failure

### Summary

We observed consistent RoCE failures (`Transport retry count exceeded`) when
multiple pods with macvlan interfaces are present on the same node. This
occurred even when the additional pod performed no RDMA activity (`sleep
infinity` with macvlan network attachments only).

The NVIDIA Network Operator documentation does show macvlan + RDMA shared device
plugin as a supported configuration. The difference between our setup and the
documented examples is unclear — it may involve BlueField-3 SuperNIC-specific
behavior, GID table handling with many interfaces per PF, or switch/NIC
interaction unique to our environment. Investigation is ongoing.

### What We Observed

**Environment:** BlueField-3 SuperNICs (device `0xa2dc`), 10 PFs per node, each
with a macvlan `NetworkAttachmentDefinition`, `nv-ipam` CIDRPool IPAM, and
`rdma/shared_roce` resource. Two worker nodes.

**Test tool:** `ucx_perftest` (from `ghcr.io/llm-d/llm-d-cuda:v0.6.0`, UCX 1.20.0)
in two pods with `podAntiAffinity` (one per node):

```bash
# Server pod:
UCX_NET_DEVICES=mlx5_0:1 UCX_TLS=rc_mlx5,ud_mlx5,self UCX_IB_TRAFFIC_CLASS=0 \
  ucx_perftest -t tag_bw -s 4194304 -n 100000 -w 64

# Client pod:
UCX_NET_DEVICES=mlx5_0:1 UCX_TLS=rc_mlx5,ud_mlx5,self UCX_IB_TRAFFIC_CLASS=0 \
  ucx_perftest <server-ip> -t tag_bw -s 4194304 -n 100000 -w 64
```

**With only the two ucx-perftest pods deployed (one per node):**
- 45 GB/s (363 Gb/s) sustained for 100K iterations on a single 400GbE NIC
- No errors, no retries

**After deploying an additional pod with macvlan interfaces on the same node**
(even a dummy pod running `sleep infinity` with no RDMA activity):
- Failure: `Transport retry count exceeded on mlx5_X:1/RoCE`
- Affected all mlx5 devices, not just the one shared with the additional pod
- `local_ack_timeout_err` NIC counter incremented — RDMA READ responses were
  never received by the initiator

**After removing the additional pod:** failure persisted until the ucx-perftest
pods themselves were deleted and recreated (new macvlan interfaces, new GIDs).

### Why `ib_write_bw` Did Not Exhibit This

`ib_write_bw` uses one-sided RDMA WRITE (data flows in one direction; remote
NIC is passive). This achieved 390+ Gb/s even with multiple macvlan pods on the
same node.

UCX's rendezvous protocol uses **RDMA READ** (receiver actively reads from
sender's memory). The failure only occurred with this bidirectional RDMA pattern.

### UCX Build Issue (Separate)

During testing we also discovered that the Red Hat UBI vLLM image
(`registry.stage.redhat.io/rhaii/vllm-cuda-rhel9`) ships UCX 1.19.1 built with
`--disable-optimizations`, which caused ~1000x performance degradation (~0.6
MB/s instead of ~14 GB/s for 65KB messages). A colleague with a different RoCE
cluster did NOT reproduce this degradation with the same image, so the
interaction may be environment-specific. The upstream image
(`ghcr.io/llm-d/llm-d-cuda:v0.6.0`, UCX 1.20.0) performs correctly. This UCX
issue is separate from the multi-pod macvlan failure.

### Current Status

We are switching to SR-IOV (Steps 10 + 13) to provide hardware-level VF
isolation per pod. The macvlan configuration remains in this directory for
reference and for single-pod-per-node use cases where it works correctly.
