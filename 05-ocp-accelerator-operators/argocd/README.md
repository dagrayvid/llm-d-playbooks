# ArgoCD Automation for OCP Accelerator Operators

## Overview

This directory provides an optional ArgoCD app-of-apps pattern for deploying accelerator operators via GitOps. A root Application deploys child Application resources, each pointing to a step in the selected case study or `common/` directory.

## Quick Start

### 1. Install OpenShift GitOps Operator

```bash
# Via OperatorHub UI, or:
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-gitops-operator
  namespace: openshift-operators
spec:
  channel: latest
  name: openshift-gitops-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
```

### 2. Configure the Root App

Edit `bootstrap/root-app.yaml`:
- Set `spec.source.repoURL` to your fork's URL
- Set `spec.source.path` to the overlay matching your case study:
  - `05-ocp-accelerator-operators/argocd/overlays/bare-metal-roce/` — Dell B200 + BlueField-3
  - `05-ocp-accelerator-operators/argocd/overlays/ibm-cloud/` — IBM Cloud VPC
  - `05-ocp-accelerator-operators/argocd/overlays/bare-metal-ib/` — InfiniBand (legacy)

### 3. Apply Bootstrap

```bash
oc apply -k 05-ocp-accelerator-operators/argocd/bootstrap/
```

This creates:
- A ClusterRoleBinding granting the GitOps controller cluster-admin
- The root Application that syncs child apps based on the selected overlay

## Platform Overlays

Each overlay's `kustomization.yaml` selects which ArgoCD Application resources to deploy:

- **bare-metal-roce**: Maps to `bare-metal-dell-b200-bf3/` case study — includes SR-IOV, NIC discovery, macvlan + SBR
- **ibm-cloud**: Maps to `ibm-cloud-vpc/` case study — operators + IBM Cloud networking (host-device + SBR)
- **bare-metal-ib**: Legacy InfiniBand overlay — skips SR-IOV and VF config

## Customization

To change the repo URL for all child apps, the root app uses a kustomize patch that replaces `spec.source.repoURL` on all Applications with the `llm-d-playbooks` managed-by label. Update the patch value in `bootstrap/root-app.yaml`.
