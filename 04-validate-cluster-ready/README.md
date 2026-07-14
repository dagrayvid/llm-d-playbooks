# Chapter 04: Validate Cluster

Validate that your cluster is ready for llm-d: Kubernetes version, llm-d dependencies, GPU resources, and RDMA networking.

We are building [rhaii-cluster-validation](https://github.com/opendatahub-io/rhaii-cluster-validation), a kubectl plugin that automates GPU, RDMA, and network checks on Kubernetes clusters. It can replace most of the manual steps below.

---

## Cluster Installation

Verify that the Kubernetes cluster is installed correctly and meets minimum requirements for llm-d.

### OCP

- Verify OpenShift cluster version >= 4.19

### xKS (AKS, CKS)

- Verify managed Kubernetes cluster version and list tested instance types

---

## llm-d Dependencies

Validate that llm-d control plane dependencies (from [Chapter 02](../02-llm-d-dependencies/)) are installed and healthy.

> **Status:** WIP -- content will be added in a later PR.

### Planned Content

- Validate required CRDs are present
- Validate pod network (non-RDMA) supports ~10 GiB cross-node bandwidth
- Operator health checks

---

## GPU Readiness

Verify that GPU resources are available on worker nodes and that the GPU operator is functioning correctly.

```bash
# Check GPU resources on nodes
oc get nodes -o custom-columns=NAME:.metadata.name,GPU:.status.allocatable.nvidia\\.com/gpu

# Check GPU operator ClusterPolicy
oc get clusterpolicy

# Verify GPU pods
oc get pods -n nvidia-gpu-operator
```

---

## RDMA Validation

> **RDMA is optional.** It is only required for distributed inference techniques that require GPUDirect RDMA, such as P/D disaggregation and Wide EP (multi-node expert parallelism). If you are deploying llm-d with intelligent routing only (no disaggregation), skip this section.

Validate GPU, network, and RDMA readiness across your cluster using the [rhaii-cluster-validation](https://github.com/red-hat-data-services/rhaii-cluster-validation) kubectl plugin.

### What It Does

| Command | What it validates | Tools used |
|---------|-------------------|------------|
| `gpu` | GPU driver version, ECC mode, GPU count | nvidia-smi |
| `network` | TCP bandwidth between all node pairs | iperf3 |
| `rdma` | RDMA bandwidth per GPU-NIC pair | ib_write_bw, ibv_rc_pingpong |
| `all` | All of the above in sequence | — |

The tool deploys two container images:
- **Controller** (`odh-rhaii-cluster-validator-rhel9:v3.4.0`) — orchestrates validation pods
- **Tools** (`odh-rhaii-validator-tools-rhel9:v3.4.0`) — runs iperf3, ib_write_bw, ibv_rc_pingpong on each node

RDMA validation uses GPU-NIC NUMA topology to pair devices correctly and runs bandwidth tests in a ring topology (every node acts as both sender and receiver).

### Prerequisites

- Cluster with RDMA networking configured — see [Chapter 03](../03-ocp-accelerator-operators/)
- GPU operator running and validated — see [GPU Readiness](#gpu-readiness) above
- `kubectl` or `oc` CLI authenticated to the cluster
- Pull secret for `registry.redhat.io` (the validation images are hosted there)

### Install the Plugin

Download the `kubectl-rhaii` binary from the [GitHub releases page](https://github.com/red-hat-data-services/rhaii-cluster-validation/releases) and place it in your PATH:

```bash
# Download the latest release (adjust version and OS/arch as needed)
curl -LO https://github.com/red-hat-data-services/rhaii-cluster-validation/releases/latest/download/kubectl-rhaii-linux-amd64
chmod +x kubectl-rhaii-linux-amd64
sudo mv kubectl-rhaii-linux-amd64 /usr/local/bin/kubectl-rhaii

# Verify installation
kubectl rhaii --help
```

Alternatively, you can run the tool via podman — see the [upstream README](https://github.com/red-hat-data-services/rhaii-cluster-validation#running-via-podman) for details.

### Step 1: Validate GPUs

Check that GPU drivers are loaded correctly and ECC is enabled on all nodes:

```bash
kubectl rhaii validate gpu
```

Expected output:

```
Validating GPU on nodes...
Node: gpu-worker-0
  GPU 0: NVIDIA H100 80GB HBM3, Driver: 535.183.01, ECC: Enabled
  GPU 1: NVIDIA H100 80GB HBM3, Driver: 535.183.01, ECC: Enabled
  ...
Node: gpu-worker-1
  GPU 0: NVIDIA H100 80GB HBM3, Driver: 535.183.01, ECC: Enabled
  ...
GPU validation: PASSED
```

If GPUs are not detected, verify the GPU operator is running (`oc get pods -n nvidia-gpu-operator`).

### Step 2: Validate TCP Network Bandwidth

Test TCP bandwidth between all node pairs using iperf3:

```bash
kubectl rhaii validate network
```

This deploys iperf3 server/client pods and measures bandwidth between every pair of GPU nodes. Expected output shows bandwidth for each node pair — look for consistent values across all pairs. Significant outliers may indicate a misconfigured NIC or switch port.

### Step 3: Validate RDMA

Test RDMA bandwidth per GPU-NIC pair using ib_write_bw:

```bash
kubectl rhaii validate rdma
```

This is the most important validation for P/D disaggregation. The tool:

1. Discovers all GPUs and RDMA-capable NICs on each node
2. Maps GPU-to-NIC pairs using NUMA topology (GPUs perform best with the NIC on the same NUMA node)
3. Runs `ib_write_bw` between node pairs in a ring topology
4. Reports per-pair bandwidth

Look for bandwidth values consistent with your NIC line rate (e.g., ~200 Gbps for ConnectX-7 at 400GbE, ~100 Gbps for ConnectX-6 at 200GbE). If any pairs show significantly lower bandwidth, check MOFED driver status, SR-IOV VF allocation, and switch QoS configuration.

### Run All Checks

To run GPU, network, and RDMA validation in one command:

```bash
kubectl rhaii validate all
```

### View the Report

After validation completes, the results are stored in a ConfigMap:

```bash
kubectl get configmap rhaii-validate-report -o yaml
```

### Clean Up

Remove all validation pods and resources:

```bash
kubectl rhaii validate clean
```

### Non-OCP Clusters (AKS, CKS, EKS)

On non-OpenShift clusters, you need to set up the namespace and pull secret before running validation:

```bash
# Create the validation namespace
kubectl create namespace rhaii-validation

# Create a pull secret for registry.redhat.io
kubectl create secret docker-registry rhai-pull-secret \
  --docker-server=registry.redhat.io \
  --docker-username=<your-username> \
  --docker-password=<your-password> \
  -n rhaii-validation

# Run validation with explicit namespace and pull secret
kubectl rhaii validate all \
  --namespace rhaii-validation \
  --pull-secret rhai-pull-secret
```

The tool auto-detects the platform (OCP, AKS, CKS, EKS) and adjusts its behavior accordingly.

### Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Image pull errors | Missing or expired pull secret for `registry.redhat.io` | Create/update the pull secret |
| RDMA tests fail with "No RDMA devices found" | MOFED driver not loaded or SR-IOV VFs not created | Check `oc get pods -n nvidia-network-operator` and verify VFs are allocated |
| Low RDMA bandwidth on some pairs | NUMA misalignment or switch QoS misconfiguration | Check GPU-NIC NUMA topology, verify DSCP trust settings on the switch |
| GPU validation fails | GPU operator not running or driver pods in CrashLoopBackOff | Check `oc get clusterpolicy` and GPU operator pod logs |
| Pods stuck in Pending | Insufficient resources or missing node labels | Check `oc describe pod` for scheduling events |
