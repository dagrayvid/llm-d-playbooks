# Chapter 03: OCP Accelerator Operators

Install and configure GPU, RDMA, and networking operators on OpenShift Container Platform.

This chapter covers NFD (Node Feature Discovery), NVIDIA GPU Operator, NVIDIA Network Operator, and SR-IOV / host-device networking. These operators are required on OCP but not on managed Kubernetes platforms (AKS, CKS).

## Case-Study Approach

RoCE on OpenShift varies dramatically between environments — different NIC models, different CNI strategies, different firmware and QoS requirements, different VLAN/subnet topologies. Rather than attempting a one-size-fits-all solution, this chapter provides **case studies**: tested, working configurations for specific environments.

Each case study is a self-contained directory with its own README, step-by-step instructions, and environment-specific manifests. Use the case study closest to your environment as a starting point, and adapt as needed.

| Case Study | Environment | NIC | RDMA Transport | CNI Strategy |
|------------|-------------|-----|----------------|--------------|
| [`bare-metal-a100-ib/`](bare-metal-a100-ib/) | Bare-metal, 4 nodes, 8x A100 per node | ConnectX-6 PFs (InfiniBand HDR) | InfiniBand | RDMA shared device plugin |
| [`bare-metal-b200-ipvlan/`](bare-metal-b200-ipvlan/) | Bare-metal, 2 nodes, 8x B200 per node | BF3 SuperNICs (legacy NIC mode) | RoCE v2 | ipvlan L2 + RDMA shared device plugin |
| [`bare-metal-xe8640-sriov/`](bare-metal-xe8640-sriov/) | Bare-metal, 2 Dell XE8640 nodes, 4x H100 per node | ConnectX-6 Dx dual-port | RoCE v2 | SR-IOV + whereabouts IPAM |
| [`ibm-cloud-vpc/`](ibm-cloud-vpc/) | IBM Cloud VPC, H100/H200 bare-metal workers | ConnectX-6 Dx VFs (hypervisor-managed) | RoCE v2 | host-device + custom SBR |

## Shared Components (`common/`)

Operator installation manifests that are identical across environments live in [`common/`](common/). Each case study references these via kustomize.

| Directory | What it installs |
|-----------|-----------------|
| `common/00-discover-gpus-nics/` | Pre-install hardware probe scripts |
| `common/01-operator-subscriptions/` | NFD, GPU Operator, Network Operator (OLM Subscriptions) |
| `common/02-nfd-operands/` | NodeFeatureDiscovery + NodeFeatureRule CRs |
| `common/20-gpu-readiness/` | Readiness gate jobs (wait for MOFED before GPU operator) |
| `common/21-gpu-operands/` | GPU Operator ClusterPolicy |

## ArgoCD (GitOps)

App-of-apps patterns for automated deployment will be added alongside case studies.

## Credits

Operator manifests and automation adapted from [Infrabric-deployer](https://github.com/bbenshab/Infrabric-deployer) by [@bbenshab](https://github.com/bbenshab). IBM Cloud networking based on the [PSAP Guide to RoCE on OCP for llm-d](https://docs.google.com/document/d/1YFnHMnb03E_0BVfMrwABMDnMFqbBBasYyXKPJqJnXV4).
