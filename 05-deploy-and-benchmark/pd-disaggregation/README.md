# Benchmarking LLM-D Prefill/Decode Disaggregation

This guide walks through deploying LLMs with prefill/decode (P/D) disaggregation in Red Hat AI Inference and Red Hat OpenShift AI. It includes a lightweight smoke test with `Qwen/Qwen3-0.6B` (2 GPUs) to validate the P/D pipeline, and a full deployment of `nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-BF16` (8 GPUs) with an optional aggregated baseline for performance comparison.

## What Is P/D Disaggregation?

In a standard (aggregated) LLM deployment, each replica handles both **prefill** (processing the input prompt to build the KV cache) and **decode** (generating tokens one at a time). These two phases have very different compute profiles:

- **Prefill** is compute-bound — it processes the entire prompt in a single forward pass, saturating GPU FLOPs
- **Decode** is memory-bandwidth-bound — it generates one token per step, reading the full KV cache each time

P/D disaggregation separates these phases onto different pod groups, each tuned for its workload:


|                   | Decode pods            | Prefill pods                          |
| ----------------- | ---------------------- | ------------------------------------- |
| **Role**          | Generate output tokens | Process input prompts, build KV cache |
| **GPU count**     | 2 (TP=2)               | 2 (TP=2)                              |
| **Replicas**      | 2                      | 2                                     |
| **Optimized for** | Memory bandwidth       | Compute throughput                    |


After a prefill pod processes a prompt, it transfers the KV cache to a decode pod via **NIXL** (NVIDIA Inference eXchange Layer) over **RDMA**, avoiding a CPU-mediated copy. This requires RDMA networking — see [Chapter 04](../../04-validate-cluster/).

## Prerequisites

- Cluster with RDMA networking configured and validated — see [Chapter 03](../../03-ocp-accelerator-operators/) and [Chapter 04](../../04-validate-cluster/)
- GPU operator running — see [Chapter 04](../../04-validate-cluster/)
- Image pull secret `rhai-pull-secret` for Red Hat AI container images
- `oc` CLI authenticated to the cluster (on non-OCP platforms, `kubectl` can be used in place of `oc` throughout this guide)
- **(OCP)** P/D pods require `IPC_LOCK` for RDMA memory registration, which is not permitted by the default restricted SCC. The operator creates a service account `<name>-kserve` for decode pods; prefill pods use the `default` SA. Grant both the `openshift-ai-llminferenceservice-scc`:

  ```bash
  oc adm policy add-scc-to-user openshift-ai-llminferenceservice-scc -z default -n <your-namespace>
  oc adm policy add-scc-to-user openshift-ai-llminferenceservice-scc -z <name>-kserve -n <your-namespace>
  ```

  For example, for the `pd-performance` deployment:

  ```bash
  oc adm policy add-scc-to-user openshift-ai-llminferenceservice-scc -z default -n <your-namespace>
  oc adm policy add-scc-to-user openshift-ai-llminferenceservice-scc -z pd-performance-kserve -n <your-namespace>
  ```

**For the smoke test:** 2 GPUs minimum (1 decode + 1 prefill)

**For the full deployment:** 8 GPUs total (2 decode replicas × 2 GPUs + 2 prefill replicas × 2 GPUs), RWX PVC named `model-cache-nemotron-30b` in the deployment namespace. The storage-initializer will download the model on first deploy, but if multiple replicas share the PVC, deploy with 1 replica first to avoid concurrent download corruption, then scale up.

## Manifest Structure

Manifests use kustomize with base + platform overlays:

```
llm-d/
  ocp-gateway.yaml                    ← GatewayClass + Gateway (OCP only, apply once)
  smoke-test/
    base/                             ← Base manifests (rdma/ib resource name)
    ocp-infiniband/                   ← OCP overlay (uses base as-is for InfiniBand)
  pd-performance/
    base/                             ← Base manifests (rdma/ib resource name)
    ocp-infiniband/                   ← OCP overlay (uses base as-is for InfiniBand)
  aggregated-baseline/
    base/                             ← Aggregated baseline (no RDMA)
guidellm/
  base/
    guidellm-job.yaml                 ← Common GuideLLM job config
  overlays/
    baseline/                         ← Targets aggregated baseline endpoint
    pd-performance/                   ← Targets P/D endpoint
```

The `base/` manifests use `rdma/ib` as the RDMA resource name. If your cluster uses a different resource name, create your own overlay or edit the base. For clusters with RoCE, you may also need Pod annotations for NetworkAttachmentDefinitions.

## OCP: Apply Gateway (Once)

On OpenShift (RHOAI), create the GatewayClass and Gateway before deploying any LLMInferenceService. Skip this on CKS/AKS.

```bash
cd 05-deploy-and-benchmark/pd-disaggregation

oc apply -f llm-d/ocp-gateway.yaml
```

If you already deployed the gateway from the [intelligent-inference-scheduler](../intelligent-inference-scheduler/) guide, this step is a no-op — the resources are cluster-scoped and shared.

---



## Smoke Test: Qwen3-0.6B (2 GPUs)

Before committing GPUs to a full P/D deployment, validate that the P/D pipeline, NIXL, and RDMA are working with a minimal `Qwen/Qwen3-0.6B` deployment: 1 decode replica + 1 prefill replica, 1 GPU each.

```bash
# OCP with InfiniBand overlay
oc apply -k llm-d/smoke-test/ocp-infiniband/

# Other platforms (uses base overlay)
oc apply -k llm-d/smoke-test/base/
```

Wait for both pods to be ready (1 decode + 1 prefill):

```bash
oc get pods -l app.kubernetes.io/name=pd-smoke-test
```

Verify RDMA resources and NIXL connectivity:

```bash
# Check RDMA resource is allocated
oc get pods -l app.kubernetes.io/name=pd-smoke-test \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].resources.limits}{"\n"}{end}'

# Check NIXL port on one of the pods
POD=$(oc get pods -l app.kubernetes.io/name=pd-smoke-test -o jsonpath='{.items[0].metadata.name}')
oc exec $POD -- ss -tlnp | grep 5600
```

Send a test request. Port-forward to the gateway service to reach it from outside the cluster. In a separate terminal:

```bash
# OCP
GW_SVC=$(oc get svc -n openshift-ingress -l gateway.networking.k8s.io/gateway-name=openshift-ai-inference -o jsonpath='{.items[0].metadata.name}')
oc port-forward -n openshift-ingress svc/$GW_SVC 8080:80

# CKS/AKS — gateway service name and namespace differ by platform
oc port-forward -n redhat-ods-applications svc/inference-gateway-istio 8080:80
```

Then send a request. The gateway uses path-based routing: `/<namespace>/<name>/v1/...`

```bash
NAMESPACE=<your-namespace>

curl -s http://localhost:8080/$NAMESPACE/pd-smoke-test/v1/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen3-0.6B",
    "prompt": "What is prefill decode disaggregation?",
    "max_tokens": 64
  }' | jq .
```

> **Note:** If Kuadrant is installed on your cluster and auth is enabled for the LLMInferenceService, the gateway enforces authentication. Add `-H "Authorization: Bearer $(oc whoami -t)"` to the curl commands.

If you get a successful response, check the logs of the Decode pods to confirm that NIXL transfers have succeeded:

```bash
$ oc logs pod/pd-smoke-test-kserve-dbdc75457-9prlp | grep "KV Transfer"
Defaulted container "main" out of: main, llm-d-routing-sidecar (init), storage-initializer (init)
(APIServer pid=428) INFO 07-13 16:33:58 [metrics.py:103] KV Transfer metrics: Num successful transfers=1, Avg xfer time (ms)=3.056, P90 xfer time (ms)=3.056, Avg post time (ms)=1.563, P90 post time (ms)=1.563, Avg MB per transfer=14.0, Throughput (MB/s)=4581.152, Avg number of descriptors=56.0
```

If your cluster has Prometheus configured, you can also verify InfiniBand traffic is flowing during inference by querying the transmitted bytes rate across GPU worker nodes:

```promql
sum by (instance, device)(
  rate(node_infiniband_port_data_transmitted_bytes_total[1m])
)
```

On OCP, you can view this in the console monitoring page or query via the Thanos Querier route, for example:

```bash
THANOS_HOST=$(oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}')
TOKEN=$(oc create token prometheus-k8s -n openshift-monitoring --duration=10m)

curl -sk \
  -H "Authorization: Bearer $TOKEN" \
  "https://$THANOS_HOST/api/v1/query" \
  --data-urlencode 'query=sum by (instance, device)(rate(node_infiniband_port_data_transmitted_bytes_total[1m])) > 0' | jq .
```

Clean up the smoke test before proceeding:

```bash
# OCP with InfiniBand overlay
oc delete -k llm-d/smoke-test/ocp-infiniband/

# Other platforms (uses base overlay)
oc delete -k llm-d/smoke-test/base/
```

---



## Full Deployment: Nemotron-3-Nano-30B (8 GPUs)

## Step 1 (Optional): Deploy Aggregated Baseline

Deploy the model as 4 aggregated replicas with TP=2 (no P/D disaggregation, 8 GPUs total) to establish a performance baseline:

```bash
oc apply -k llm-d/aggregated-baseline/base/
```

Wait for all 4 replicas to be ready (model download may take time on first deploy):

```bash
oc get pods -l app.kubernetes.io/name=nemotron-30b
```

Verify the model is serving (assumes port-forward is still running from the smoke test — if not, start it again):

```bash
NAMESPACE=<your-namespace>

curl -s http://localhost:8080/$NAMESPACE/nemotron-30b/v1/models | jq .
```



## Step 2 (Optional): Benchmark Baseline

Run [GuideLLM](https://github.com/neuralmagic/guidellm) from inside the cluster to benchmark the aggregated deployment. The GuideLLM job is configured as a kustomize base with overlays for each target. Before running, update the target URL in `guidellm/overlays/baseline/kustomization.yaml` to match your gateway service and namespace.

```bash
oc apply -k guidellm/overlays/baseline/
oc logs -f job/baseline-guidellm-benchmark
```

Take note of the latency and throughput results from the logs. When done, delete the job before running the next benchmark:

```bash
oc delete job baseline-guidellm-benchmark
```

## Step 3: Deploy P/D Disaggregation

Remove the aggregated baseline (if deployed) and deploy the P/D configuration:

```bash
# Remove baseline (skip if you didn't deploy it)
oc delete -k llm-d/aggregated-baseline/base/

# Deploy P/D
# OCP with InfiniBand overlay
oc apply -k llm-d/pd-performance/ocp-infiniband/

# Other platforms (uses base overlay)
oc apply -k llm-d/pd-performance/base/
```

Wait for decode and prefill pods (2 decode + 2 prefill):

```bash
oc get pods -l app.kubernetes.io/name=pd-performance
```

You should see 4 model-serving pods: 2 decode and 2 prefill. Verify RDMA resources are allocated:

```bash
oc get pods -l app.kubernetes.io/name=pd-performance \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].resources.limits}{"\n"}{end}'
```



### Verify NIXL Connectivity

Check that the NIXL side-channel is running on each pod:

```bash
POD=$(oc get pods -l app.kubernetes.io/name=pd-performance -o jsonpath='{.items[0].metadata.name}')
oc exec $POD -- ss -tlnp | grep 5600
```



## Step 4: Benchmark P/D

Run GuideLLM against the P/D deployment. Before running, update the target URL in `guidellm/overlays/pd-performance/kustomization.yaml` to match your gateway service and namespace.

```bash
oc apply -k guidellm/overlays/pd-performance/
oc logs -f job/pd-guidellm-benchmark
```

Compare the latency and throughput results against the baseline run. When done:

```bash
oc delete job pd-guidellm-benchmark
```

## Step 5: Compare Results

### Test conditions

Both deployments used 8 GPUs with the same model (`nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-BF16`), workload (1024 requests, ~8000 input tokens, ~500 output tokens), and concurrency (64 streams). Benchmarked with [GuideLLM](https://github.com/neuralmagic/guidellm). Raw results are in [`results/`](results/).

| Configuration | Replicas | TP | Total GPUs |
|---------------|----------|----|------------|
| Aggregated baseline | 4 | 2 | 8 |
| P/D decode | 2 | 2 | 4 |
| P/D prefill | 2 | 2 | 4 |

### Performance Results

| Metric | Aggregated | P/D | Change |
|--------|------------|-----|--------|
| **Throughput (output tok/s)** | 2,834 | 3,235 | **+14%** |
| **Throughput (req/s)** | 4.5 | 6.2 | **+38%** |
| **p95 TTFT** | 47,927 ms | 7,027 ms | **−85%** |
| **p95 ITL** | 27.0 ms | 17.8 ms | **−34%** |
| **p95 End-to-end latency** | 57.1 s | 16.3 s | **−71%** |
| **Median end-to-end latency** | 10.9 s | 9.8 s | −10% |

### Key takeaways

- **Tail latency dramatically reduced** — p95 TTFT drops from ~48s to ~7s (6.8x). P/D prevents prefill requests from queuing behind decode work under high concurrency.
- **Decode latency improves** — p95 ITL drops 34% (27 → 18 ms). Dedicated decode pods produce tokens faster and more consistently.
- **Throughput up 14–38%** — the same 1024-request workload completes faster

> **Note:** These results are specific to this model, TP configuration, and traffic pattern (long prompts, 64 concurrent streams). Performance impact will vary with model size, deployment configuration, and workload characteristics.

## Understanding the P/D Manifest

The P/D manifest (`[llm-d/pd-performance/base/llminferenceservice.yaml](llm-d/pd-performance/base/llminferenceservice.yaml)`) has three key sections:

### Decode pods (`spec.template`)

```yaml
spec:
  model:
    name: nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-BF16
    uri: hf://nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-BF16
  replicas: 2
  template:
    containers:
      - name: main
        env:
          - name: VLLM_ADDITIONAL_ARGS
            value: --tensor-parallel-size 2 ...
        resources:
          limits:
            nvidia.com/gpu: '2'
            rdma/ib: '1'
```

- **2 replicas with TP=2** — decode is memory-bandwidth-bound; separating decode from prefill lets these pods focus on token generation
- `rdma/ib: '1'` — requests one RDMA device for KV cache transfers (resource name varies by platform — see [Manifest Structure](#manifest-structure))
- `IPC_LOCK` **capability** — required for RDMA memory registration (pinned memory)



### Prefill pods (`spec.prefill`)

```yaml
  prefill:
    replicas: 2
    template:
      containers:
        - name: main
          env:
            - name: VLLM_ADDITIONAL_ARGS
              value: --tensor-parallel-size 2 --gpu-memory-utilization 0.88 ...
```

- **2 replicas with TP=2** — prefill is compute-bound; multiple smaller replicas process prompts in parallel
- `gpu-memory-utilization 0.88` — slightly lower than default to leave headroom for KV cache transfers
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

- `NixlConnector` — uses NVIDIA's NIXL library for zero-copy KV cache transfer over RDMA
- `kv_role: kv_both` — each pod can both send and receive KV cache data
- **Port 5600** — NIXL side-channel for coordination between pods
- `--block-size 128` — KV cache block size, must match across all pods
- `--no-disable-hybrid-kv-cache-manager` — enables the hybrid KV cache manager for efficient memory management during transfers



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
# OCP
oc delete -k llm-d/pd-performance/ocp-infiniband/

# Other platforms (uses base overlay)
oc delete -k llm-d/pd-performance/base/

# Remove baseline if deployed
oc delete -k llm-d/aggregated-baseline/base/

# Remove gateway (OCP only, if no other LLMInferenceService deployments need it)
oc delete -f llm-d/ocp-gateway.yaml
```

