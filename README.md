# LLM-D Deployment Playbooks

## Overview

This repository contains playbooks for deploying and validating [llm-d](https://github.com/llm-d/llm-d) across multiple Kubernetes platforms.

## Tested Platforms

| Platform | Documentation |
|----------|--------------|
| OpenShift Container Platform | [Installation overview](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/installation_overview/ocp-installation-overview) |
| Azure Kubernetes Service (AKS) | [AKS quickstart](https://learn.microsoft.com/en-us/azure/aks/learn/quick-kubernetes-deploy-portal) |
| CoreWeave Kubernetes Service (CKS) | [CKS introduction](https://docs.coreweave.com/products/cks) |

## Deployment Steps

| Chapter | Directory | Purpose | OCP | xKS |
|---------|-----------|---------|-----|-----|
| 1 | [01-cluster-install/](01-cluster-install/) | Install and bootstrap a Kubernetes cluster | Y | Y |
| 2 | [02-validate-cluster-install/](02-validate-cluster-install/) | Verify cluster meets minimum requirements | Y | Y |
| 3 | [03-llm-d-dependencies/](03-llm-d-dependencies/) | Install llm-d operators (cert-manager, service mesh, KServe, etc.) | Y | Y |
| 4 | [04-validate-llm-d-dependencies/](04-validate-llm-d-dependencies/) | Validate CRDs and pod network bandwidth | Y | Y |
| 5 | [05-ocp-accelerator-operators/](05-ocp-accelerator-operators/) | Install GPU, RDMA, and networking operators (NFD, GPU, Network, SR-IOV) | Y | N |
| 6 | [06-validate-gpu-readiness/](06-validate-gpu-readiness/) | Verify GPU resources are available on nodes | Y | Y |
| 7 | [07-rdma-validation/](07-rdma-validation/) | Validate RDMA connectivity, bandwidth, and latency | Y | Y |
| 8 | [08-deploy-and-benchmark/](08-deploy-and-benchmark/) | Deploy llm-d and benchmark performance | Y | Y |

## Chapter 5: OCP Accelerator Operators

Chapter 5 is organized as **case studies** — tested, working configurations for specific environments. GPU and RDMA operator configuration varies too much between environments for a one-size-fits-all approach. The `common/` directory contains shared operator subscriptions (NFD, GPU Operator, NVIDIA Network Operator) used across all case studies.

Case studies will be added as they are validated. See the [Chapter 5 README](05-ocp-accelerator-operators/README.md) for details on the case-study pattern.
