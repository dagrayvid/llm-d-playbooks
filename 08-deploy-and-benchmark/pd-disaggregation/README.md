# Benchmarking LLM-D Prefill/Decode Disaggregation

This guide walks through deploying with prefill/decode (P/D) disaggregation. It includes a lightweight smoke test with `Qwen/Qwen3-0.6B` (2 GPUs) to validate the P/D pipeline, and a full-scale deployment of `openai/gpt-oss-120b` (16 GPUs) with an optional aggregated baseline for performance comparison.

## What Is P/D Disaggregation?

In a standard (aggregated) LLM deployment, each replica handles both **prefill** (processing the input prompt to build the KV cache) and **decode** (generating tokens one at a time). These two phases have very different compute profiles:

- **Prefill** is compute-bound — it processes the entire prompt in a single forward pass, saturating GPU FLOPs
- **Decode** is memory-bandwidth-bound — it generates one token per step, reading the full KV cache each time

P/D disaggregation separates these phases onto different pod groups, each tuned for its workload:

| | Decode pods | Prefill pods |
|--|-------------|-------------|
| **Role** | Generate output tokens | Process input prompts, build KV cache |
| **GPU count** | 4 (TP=4) | 2 (TP=2) |
| **Replicas** | 2 | 4 |
| **Optimized for** | Memory bandwidth | Compute throughput |

After a prefill pod processes a prompt, it transfers the KV cache to a decode pod via **NIXL** (NVIDIA Inference eXchange Layer) over **RDMA**, avoiding a CPU-mediated copy. This requires RDMA networking — see [Chapter 07](../../07-rdma-validation/).

## Prerequisites

- Cluster with RDMA networking configured and validated — see [Chapter 05](../../05-ocp-accelerator-operators/) and [Chapter 07](../../07-rdma-validation/)
- GPU operator running — see [Chapter 06](../../06-validate-gpu-readiness/)
- Image pull secret `rhai-pull-secret` for Red Hat AI container images
- `oc` or `kubectl` CLI authenticated to the cluster

**For the smoke test:** 2 GPUs minimum (1 decode + 1 prefill)

**For the full deployment:** 16 GPUs total (2 decode replicas × 4 GPUs + 4 prefill replicas × 2 GPUs), PVC `model-cache-pvc` with `openai/gpt-oss-120b` downloaded

---

## Smoke Test: Qwen3-0.6B (2 GPUs)

Before committing 16 GPUs to a full-scale P/D deployment, validate that the P/D pipeline, NIXL, and RDMA are working with a minimal `Qwen/Qwen3-0.6B` deployment: 1 decode replica + 1 prefill replica, 1 GPU each.

```bash
cd 08-deploy-and-benchmark/pd-disaggregation

oc apply -f llm-d/qwen-smoke-test.yaml

# Wait for both pods to be ready
oc wait --for=condition=ready pod -l app.kubernetes.io/name=pd-smoke-test \
  --timeout=600s

# Verify 2 pods running (1 decode + 1 prefill)
oc get pods -l app.kubernetes.io/name=pd-smoke-test
```

Verify RDMA resources and NIXL connectivity:

```bash
# Check rdma/ib is allocated
oc get pods -l app.kubernetes.io/name=pd-smoke-test \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].resources.limits}{"\n"}{end}'

# Check NIXL port on one of the pods
POD=$(oc get pods -l app.kubernetes.io/name=pd-smoke-test -o jsonpath='{.items[0].metadata.name}')
oc exec $POD -- ss -tlnp | grep 5600
```

Send a test request:

```bash
export INFERENCE_URL=$(oc get inferenceservice pd-smoke-test -o jsonpath='{.status.url}')

curl -s "$INFERENCE_URL/v1/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen3-0.6B",
    "prompt": "What is prefill decode disaggregation?",
    "max_tokens": 64
  }' | jq .
```

If you get a successful response, the P/D pipeline is working. Clean up the smoke test before proceeding:

```bash
oc delete -f llm-d/qwen-smoke-test.yaml
```

---

## Full Deployment: gpt-oss-120b (16 GPUs)

## Step 1 (Optional): Deploy Aggregated Baseline

Deploy the model as a single aggregated replica (no P/D disaggregation) to establish a performance baseline:

```bash
cd 08-deploy-and-benchmark/pd-disaggregation

oc apply -f llm-d/aggregated-baseline.yaml

# Wait for the pod to be ready (model download may take time on first deploy)
oc wait --for=condition=ready pod -l app.kubernetes.io/name=gpt-oss-120b \
  --timeout=1200s
```

Verify the model is serving:

```bash
# Get the inference endpoint
export INFERENCE_URL=$(oc get inferenceservice gpt-oss-120b -o jsonpath='{.status.url}')

# Test with a simple request
curl -s "$INFERENCE_URL/v1/models" | jq .
```

## Step 2 (Optional): Benchmark Baseline

Run a quick throughput test against the aggregated deployment:

```bash
curl -s "$INFERENCE_URL/v1/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "openai/gpt-oss-120b",
    "prompt": "Explain the concept of prefill and decode in large language model inference.",
    "max_tokens": 256
  }' | jq .
```

Record the latency and throughput for comparison. For a more thorough benchmark, use [GuideLLM](https://github.com/neuralmagic/guidellm) or a similar load testing tool.

## Step 3: Deploy P/D Disaggregation

Remove the aggregated baseline (if deployed) and deploy the P/D configuration:

```bash
# Remove baseline (skip if you didn't deploy it)
oc delete -f llm-d/aggregated-baseline.yaml

# Deploy P/D
oc apply -f llm-d/pd-performance.yaml

# Wait for decode pods (2 replicas × 4 GPUs each)
oc wait --for=condition=ready pod -l app.kubernetes.io/name=pd-performance \
  --timeout=1200s

# Check all pods
oc get pods -l app.kubernetes.io/name=pd-performance
```

You should see 6 model-serving pods: 2 decode and 4 prefill. Verify RDMA resources are allocated:

```bash
# Check that rdma/ib resources are assigned
oc get pods -l app.kubernetes.io/name=pd-performance \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].resources.limits}{"\n"}{end}'
```

Each pod should show `rdma/ib: 1` in its resource limits.

### Verify NIXL Connectivity

Check that the NIXL side-channel is running on each pod:

```bash
# Pick any model pod
POD=$(oc get pods -l app.kubernetes.io/name=pd-performance -o jsonpath='{.items[0].metadata.name}')

# Check NIXL port is listening
oc exec $POD -- ss -tlnp | grep 5600
```

## Step 4: Benchmark P/D

Run the same benchmark against the P/D deployment:

```bash
export INFERENCE_URL=$(oc get inferenceservice pd-performance -o jsonpath='{.status.url}')

curl -s "$INFERENCE_URL/v1/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "openai/gpt-oss-120b",
    "prompt": "Explain the concept of prefill and decode in large language model inference.",
    "max_tokens": 256
  }' | jq .
```

For load testing, use GuideLLM with concurrent requests to exercise the P/D pipeline under load.

## Step 5 (Optional): Compare Results

With P/D disaggregation, you should observe:

- **Lower time-to-first-token (TTFT)** — dedicated prefill pods process prompts without competing with decode work
- **Higher throughput under load** — decode pods are not interrupted by incoming prefill requests
- **Better GPU utilization** — each pod group is sized for its workload (TP=4 for decode, TP=2 for prefill)

The benefits are most pronounced under high concurrency, where aggregated deployments suffer from prefill requests blocking decode progress.

## Understanding the P/D Manifest

The P/D manifest ([`llm-d/pd-performance.yaml`](llm-d/pd-performance.yaml)) has three key sections:

### Decode pods (`spec.model`)

```yaml
spec:
  model:
    replicas: 2
    template:
      containers:
        - name: main
          env:
            - name: VLLM_ADDITIONAL_ARGS
              value: --tensor-parallel-size 4 ...
          resources:
            limits:
              nvidia.com/gpu: '4'
              rdma/ib: '1'
```

- **2 replicas with TP=4** — each decode pod uses 4 GPUs with tensor parallelism, maximizing memory bandwidth for token generation
- **`rdma/ib: '1'`** — requests one RDMA virtual function for KV cache transfers
- **`IPC_LOCK` capability** — required for RDMA memory registration (pinned memory)

### Prefill pods (`spec.prefill`)

```yaml
  prefill:
    replicas: 4
    template:
      containers:
        - name: main
          env:
            - name: VLLM_ADDITIONAL_ARGS
              value: --tensor-parallel-size 2 --gpu-memory-utilization 0.88 ...
```

- **4 replicas with TP=2** — prefill is compute-bound so more, smaller replicas process prompts in parallel
- **`gpu-memory-utilization 0.88`** — slightly lower than default to leave headroom for KV cache transfers
- Same RDMA and NIXL configuration as decode pods

### KV cache transfer (NIXL)

Both decode and prefill pods include:

```yaml
env:
  - name: VLLM_NIXL_SIDE_CHANNEL_HOST
    valueFrom:
      fieldRef:
        fieldPath: status.podIP
  - name: VLLM_ADDITIONAL_ARGS
    value: ... --kv-transfer-config '{"kv_connector":"NixlConnector","kv_role":"kv_both"}'
ports:
  - containerPort: 5600
    name: nixl
    protocol: TCP
```

- **`NixlConnector`** — uses NVIDIA's NIXL library for zero-copy KV cache transfer over RDMA
- **`kv_role: kv_both`** — each pod can both send and receive KV cache data
- **Port 5600** — NIXL side-channel for coordination between pods
- **`--block-size 128`** — KV cache block size, must match across all pods
- **`--no-disable-hybrid-kv-cache-manager`** — enables the hybrid KV cache manager for efficient memory management during transfers

### Scheduler

```yaml
  scheduler:
    template:
      containers:
        - name: main
          args:
            - -v=10
```

The scheduler routes incoming requests to prefill pods and manages the handoff to decode pods after KV cache transfer. The `-v=10` flag enables verbose logging for debugging.

## Clean Up

```bash
# Remove P/D deployment
oc delete -f llm-d/pd-performance.yaml

# Or remove baseline if that's what's deployed
oc delete -f llm-d/aggregated-baseline.yaml
```
