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
| 2 | [02-llm-d-dependencies/](02-llm-d-dependencies/) | Install llm-d operators (cert-manager, service mesh, KServe, etc.) | Y | Y |
| 3 | [03-ocp-accelerator-operators/](03-ocp-accelerator-operators/) | Install GPU, RDMA, and networking operators (NFD, GPU, Network, SR-IOV) | Y | N |
| 4 | [04-validate-cluster/](04-validate-cluster/) | Validate cluster, GPU, and RDMA readiness | Y | Y |
| 5 | [05-deploy-and-benchmark/](05-deploy-and-benchmark/) | Deploy llm-d and benchmark performance | Y | Y |

## Chapter 3: OCP Accelerator Operators

Chapter 3 is organized as **case studies** — tested, working configurations for specific environments. GPU and RDMA operator configuration varies too much between environments for a one-size-fits-all approach. The `common/` directory contains shared operator subscriptions (NFD, GPU Operator, NVIDIA Network Operator) used across all case studies.

Case studies will be added as they are validated. See the [Chapter 3 README](03-ocp-accelerator-operators/README.md) for details on the case-study pattern.
