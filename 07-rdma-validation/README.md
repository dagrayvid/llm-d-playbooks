# Chapter 07: RDMA Validation

Validate RDMA network performance and connectivity after accelerator operators are deployed (Chapter 05).

## Validation Tooling

We are building [rhaii-cluster-validation](https://github.com/opendatahub-io/rhaii-cluster-validation), a hardware validation tool for GPU, RDMA, and network checks on Kubernetes clusters. It runs per-node checks (GPU drivers, ECC, RDMA devices, NIC link state) and cross-node bandwidth tests (iperf3, `ib_write_bw`) to validate cluster readiness for llm-d / RHAII inference workloads.

## Scripts

| Script | Purpose |
|--------|---------|
| `rdma-crossnode-matrix.sh` | Full cross-node RDMA bandwidth matrix across all NIC pairs |
| `rdma-bw-test.sh` | Single-pair `ib_write_bw` bandwidth test |
| `run-ib-write-bw.sh` | Wrapper for GPUDirect `ib_write_bw --use_cuda` |
| `rdma-gpu-nic-allpairs.sh` | Test all GPU-NIC pair combinations |
| `rdma-gpu-nic-intranode.sh` | Intra-node GPU-NIC bandwidth |
| `check-gpu-rdma-readiness.sh` | Pre-flight: verify GPU + RDMA devices are present |
| `gpu-nic-topo.sh` | Dump GPU-NIC NUMA/PCIe topology |
| `pcie-gpu-nic-tree.sh` | PCIe tree with GPU and NIC annotations |
| `pod-rdma-macvlan-diag.sh` | In-pod diagnostic: map GPU -> HCA -> PF -> macvlan -> IP |
| `run-diag-macvlan.sh` | Run the macvlan diagnostic across all GPU pods |
| `sriov-gpu-nic-map.sh` | Map SR-IOV VFs to GPUs |
| `ucx-export-pix-nics-for-visible-gpus.sh` | Export UCX env vars for PIX-aligned NICs |

## Test Pod Manifests

| Manifest | Purpose |
|----------|---------|
| `rdma-macvlan-test-pod.yaml` | Single RDMA test pod with macvlan interfaces |
| `rdma-macvlan-4gpu-test-pods.yaml` | 4-GPU RDMA test pods (macvlan) |
| `rdma-macvlan-shared-roce-test-pods.yaml` | Shared RoCE device plugin test pods |
| `rdma-macvlan-shared-roce-4pod-test.yaml` | 4-pod shared RoCE test |
| `rdma-gpu-test-pod.yaml` | GPUDirect RDMA test pod |
| `rdma-sriov-test-pods.yaml` | SR-IOV RDMA test pods |
| `rdma-sriov-crossnode-test-pods.yaml` | Cross-node SR-IOV RDMA test |
| `rdma-sriov-gpu-test-pods.yaml` | SR-IOV + GPU RDMA test pods |
| `ucx-perftest-pods.yaml` | UCX perftest pods |
| `ucx-perftest-pods-upstream.yaml` | UCX perftest (upstream image) |

## Other

| File | Purpose |
|------|---------|
| `nic-qos-baseline-settings.txt` | Baseline NIC QoS settings for reference |

## Success Criteria

- All nodes can communicate over the RDMA network
- Bandwidth meets minimum requirements for the NIC type (e.g., ~370+ Gb/s on NDR200 with PIX alignment)
- No packet drops or errors
- GPUDirect RDMA works (`ib_write_bw --use_cuda`) without `ENOMEM` or `LOC_PROT_ERR`
