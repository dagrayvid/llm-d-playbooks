# Chapter 05: OCP Accelerator Operators

Install and configure GPU, RDMA, and networking operators on OpenShift Container Platform.

This chapter covers NFD (Node Feature Discovery), NVIDIA GPU Operator, NVIDIA Network Operator, and SR-IOV / host-device networking. These operators are required on OCP but not on managed Kubernetes platforms (AKS, CKS).

## Case-Study Approach

RoCE on OpenShift varies dramatically between environments — different NIC models, different CNI strategies, different firmware and QoS requirements, different VLAN/subnet topologies. Rather than attempting a one-size-fits-all solution, this chapter provides **case studies**: tested, working configurations for specific environments.

Each case study is a self-contained directory with its own README, step-by-step instructions, and environment-specific manifests. Use the case study closest to your environment as a starting point, and adapt as needed.

| Case Study | Environment | NIC | CNI Strategy |
|------------|-------------|-----|-------------|
| [`ibm-cloud-vpc/`](ibm-cloud-vpc/) | IBM Cloud VPC bare-metal workers | ConnectX-6 Dx VFs (hypervisor-managed) | host-device + SBR |
| [`bare-metal-dell-b200-bf3/`](bare-metal-dell-b200-bf3/) | Dell MX750c, 2 nodes, 8x B200 per node | BlueField-3 / ConnectX-7 PFs | macvlan + RDMA shared device plugin + SBR |

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

App-of-apps patterns for each case study. See [`argocd/README.md`](argocd/README.md).

## Credits

Operator manifests and automation adapted from [Infrabric-deployer](https://github.com/bbenshab/Infrabric-deployer) by [@bbenshab](https://github.com/bbenshab). IBM Cloud networking based on the [PSAP Guide to RoCE on OCP for llm-d](https://docs.google.com/document/d/1YFnHMnb03E_0BVfMrwABMDnMFqbBBasYyXKPJqJnXV4).
