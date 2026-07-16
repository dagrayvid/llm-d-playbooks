# Chapter 02: llm-d Dependencies

Install the operators and platform dependencies required for llm-d deployment. The required dependencies differ by platform — refer to the appropriate installation guide below.

## Installation Guides

| Platform | Guide |
|----------|-------|
| OpenShift Container Platform (4.19+) | [Red Hat OpenShift AI — Installing and Deploying](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/installing_and_uninstalling_openshift_ai_self-managed/installing-and-deploying-openshift-ai_install#requirements-for-openshift-ai-self-managed_install) |
| Managed Kubernetes (AKS / CKS, K8s 1.33+) | [Deploy Distributed Inference with llm-d on AKS or CKS](https://docs.redhat.com/en/documentation/red_hat_ai_inference/3.4/html/deploy_distributed_inference_with_llm-d_on_azure_or_coreweave_kubernetes_service/deploying-llmd-on-xks_llmd-on-xks) |

## Component Comparison

| Component | OpenShift Container Platform | Managed Kubernetes |
|-----------|------------------------------|---------------------|
| TLS certificates | cert-manager Operator | cert-manager |
| Service mesh / gateway | Service Mesh 3 (Istio-based) | Istio via Sail Operator |
| Auth / rate-limiting | Red Hat Connectivity Link (Kuadrant) | — |
| Inference controller | KServe (via RHOAI) | KServe (via Helm) |
| Multi-node inference | LeaderWorkerSet Operator | LeaderWorkerSet |
| GPU support | NVIDIA GPU Operator (see [Chapter 03](../03-accelerator-operator-config/)) | NVIDIA device plugin (pre-installed on CKS; manual on AKS) |
| Load balancer | MetalLB (bare metal) | Cloud provider LB (built-in) |

## Next Steps

Once these dependencies are installed, proceed to [Chapter 03: Accelerator Operator Config](../03-accelerator-operator-config/) (OCP only) or [Chapter 04: Validate Cluster](../04-validate-cluster-ready/) to confirm they are healthy.

