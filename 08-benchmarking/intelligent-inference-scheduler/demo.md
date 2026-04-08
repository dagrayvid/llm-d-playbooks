# Deploy Qwen Model - vLLM and LLM-D

## Prerequisites

- OpenShift cluster with 8 L40S GPU nodes
- `oc` CLI logged in with cluster-admin privileges
- NVIDIA GPU and NFD operatord deployed
- RHOAI and LWS operators installed and deployed

## 1. Create Namespace

```bash
cat << 'EOF' | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  annotations:
    openshift.io/display-name: Demo - LLM-d
  labels:
    openshift.io/cluster-monitoring: "true"
  name: demo-llm
EOF
```

---

## 2. Deploy with vLLM

### 2a. ServingRuntime

```bash
cat << 'EOF' | oc apply -f -
apiVersion: serving.kserve.io/v1alpha1
kind: ServingRuntime
metadata:
  name: vllm-runtime
  namespace: demo-llm
spec:
  annotations:
    opendatahub.io/kserve-runtime: vllm
    prometheus.io/path: /metrics
    prometheus.io/port: '8000'
  containers:
    - args:
        - '--port=8000'
        - '--model=/mnt/models'
        - '--served-model-name={{.Name}}'
        - '--max-model-len=16000'
      command:
        - python
        - '-m'
        - vllm.entrypoints.openai.api_server
      env:
        - name: HF_HOME
          value: /tmp/hf_home
      image: 'registry.redhat.io/rhaiis/vllm-cuda-rhel9@sha256:ad756c01ec99a99cc7d93401c41b8d92ca96fb1ab7c5262919d818f2be4f3768'
      name: kserve-container
      ports:
        - containerPort: 8000
          protocol: TCP
  multiModel: false
  supportedModelFormats:
    - autoSelect: true
      name: vLLM
EOF
```

### 2b. InferenceService

```bash
cat << 'EOF' | oc apply -f -
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: qwen-vllm
  namespace: demo-llm
  annotations:
    serving.kserve.io/deploymentMode: RawDeployment
spec:
  predictor:
    automountServiceAccountToken: false
    maxReplicas: 4
    minReplicas: 4
    model:
      modelFormat:
        name: vLLM
      name: ''
      resources:
        limits:
          cpu: '4'
          memory: 8Gi
          nvidia.com/gpu: '1'
        requests:
          cpu: '4'
          memory: 8Gi
          nvidia.com/gpu: '1'
      runtime: vllm-runtime
      storageUri: "hf://Qwen/Qwen3-0.6B"
    tolerations:
      - key: "nvidia.com/gpu"
        operator: "Exists"
EOF
```

### 2c. Load Balancer Service

```bash
cat << 'EOF' | oc apply -f -
apiVersion: v1
kind: Service
metadata:
  name: qwen-vllm-lb
  namespace: demo-llm
spec:
  type: ClusterIP
  selector:
    app: isvc.qwen-vllm-predictor
  ports:
    - port: 8000
      targetPort: 8000
EOF
```

### 2d. PodMonitor

```bash
cat << 'EOF' | oc apply -f -
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: qwen-vllm-monitor
  namespace: demo-llm
spec:
  selector:
    matchLabels:
      serving.kserve.io/inferenceservice: qwen-vllm
  podMetricsEndpoints:
    - port: "8000"
      path: /metrics
      interval: 30s
  namespaceSelector:
    matchNames:
      - demo-llm
EOF
```

### vLLM Internal Endpoint

```
http://qwen-vllm-lb.demo-llm.svc.cluster.local:8000/v1
```

Test it:

```bash
curl http://qwen-vllm-lb.demo-llm.svc.cluster.local:8000/v1/models
```

```bash
curl http://qwen-vllm-lb.demo-llm.svc.cluster.local:8000/v1/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "qwen-vllm", "prompt": "Hello", "max_tokens": 50}'
```

---

## 3. Deploy with LLM-D

### 3a. GatewayClass and Gateway

```bash
cat << 'EOF' | oc apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: openshift-default
spec:
  controllerName: openshift.io/gateway-controller/v1
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: openshift-ai-inference
  namespace: openshift-ingress
spec:
  gatewayClassName: openshift-default
  listeners:
    - name: http
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: All
EOF
```

### 3b. HardwareProfile

```bash
cat << 'EOF' | oc apply -f -
apiVersion: infrastructure.opendatahub.io/v1
kind: HardwareProfile
metadata:
  annotations:
    opendatahub.io/dashboard-feature-visibility: '[]'
    opendatahub.io/disabled: 'false'
    opendatahub.io/display-name: gpu-profile
  name: gpu-profile
  namespace: redhat-ods-applications
spec:
  identifiers:
    - defaultCount: '1'
      displayName: CPU
      identifier: cpu
      maxCount: '8'
      minCount: 1
      resourceType: CPU
    - defaultCount: 12Gi
      displayName: Memory
      identifier: memory
      maxCount: 16Gi
      minCount: 1Gi
      resourceType: Memory
    - defaultCount: 1
      displayName: GPU
      identifier: nvidia.com/gpu
      maxCount: 4
      minCount: 1
      resourceType: Accelerator
EOF
```

### 3c. LLMInferenceService

```bash
cat << 'EOF' | oc apply -f -
apiVersion: serving.kserve.io/v1alpha1
kind: LLMInferenceService
metadata:
  name: qwen
  namespace: demo-llm
  annotations:
    opendatahub.io/model-type: generative
    openshift.io/display-name: qwen
    security.opendatahub.io/enable-auth: 'false'
spec:
  replicas: 4
  model:
    uri: "hf://Qwen/Qwen3-0.6B"
    name: "Qwen/Qwen3-0.6B"
  router:
    scheduler:
      template:
        containers:
          - name: main
            env:
              - name: TOKENIZER_CACHE_DIR
                value: /tmp/tokenizer-cache
              - name: HF_HOME
                value: /tmp/tokenizer-cache
              - name: TRANSFORMERS_CACHE
                value: /tmp/tokenizer-cache
              - name: XDG_CACHE_HOME
                value: /tmp
            args:
              - -v=4
              - '--cert-path'
              - /var/run/kserve/tls
              - --pool-group
              - inference.networking.x-k8s.io
              - '--pool-name'
              - '{{ ChildName .ObjectMeta.Name `-inference-pool` }}'
              - '--pool-namespace'
              - '{{ .ObjectMeta.Namespace }}'
              - '--zap-encoder'
              - json
              - '--grpc-port'
              - '9002'
              - '--grpc-health-port'
              - '9003'
              - '--secure-serving'
              - '--model-server-metrics-scheme'
              - https
              - --kv-cache-usage-percentage-metric
              - "vllm:kv_cache_usage_perc"
              - '--config-text'
              - |
                apiVersion: inference.networking.x-k8s.io/v1alpha1
                kind: EndpointPickerConfig
                plugins:
                - type: single-profile-handler
                - type: queue-scorer
                - type: active-request-scorer
                - type: prefix-cache-scorer
                schedulingProfiles:
                - name: default
                  plugins:
                  - pluginRef: queue-scorer
                    weight: 2
                  - pluginRef: active-request-scorer
                    weight: 2
                  - pluginRef: prefix-cache-scorer
                    weight: 3
            volumeMounts:
              - name: tokenizer-cache
                mountPath: /tmp/tokenizer-cache
              - name: cachi2-cache
                mountPath: /cachi2
        volumes:
          - name: tokenizer-cache
            emptyDir: {}
          - name: cachi2-cache
            emptyDir: {}
    route: { }
    gateway: { }
  template:
    tolerations:
      - key: "nvidia.com/gpu"
        operator: "Exists"
        effect: "NoSchedule"
    containers:
      - name: main
        env:
          - name: VLLM_ADDITIONAL_ARGS
            value: "--disable-uvicorn-access-log --max-model-len=16000"
        resources:
          limits:
            cpu: '4'
            memory: 8Gi
            nvidia.com/gpu: "1"
          requests:
            cpu: '4'
            memory: 8Gi
            nvidia.com/gpu: "1"
        livenessProbe:
          httpGet:
            path: /health
            port: 8000
            scheme: HTTPS
          initialDelaySeconds: 120
          periodSeconds: 30
          timeoutSeconds: 30
          failureThreshold: 5
EOF
```

### LLM-D Internal Endpoint

```
http://openshift-ai-inference-openshift-default.openshift-ingress.svc.cluster.local/demo-llm/qwen/v1
```

Test it:

```bash
curl http://openshift-ai-inference-openshift-default.openshift-ingress.svc.cluster.local/demo-llm/qwen/v1/models
```

```bash
curl http://openshift-ai-inference-openshift-default.openshift-ingress.svc.cluster.local/demo-llm/qwen/v1/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "Qwen/Qwen3-0.6B", "prompt": "Hello", "max_tokens": 50}'
```

---

## Endpoints Summary

| Deployment | Internal Endpoint |
|------------|-------------------|
| vLLM | `http://qwen-vllm-lb.demo-llm.svc.cluster.local:8000/v1` |
| LLM-D | `http://openshift-ai-inference-openshift-default.openshift-ingress.svc.cluster.local/demo-llm/qwen/v1` |

---

## Cleanup

```bash
# Remove vLLM deployment
oc delete inferenceservice qwen-vllm -n demo-llm
oc delete servingruntime vllm-runtime -n demo-llm
oc delete service qwen-vllm-lb -n demo-llm
oc delete podmonitor qwen-vllm-monitor -n demo-llm

# Remove LLM-D deployment
oc delete llminferenceservice qwen -n demo-llm
oc delete gateway openshift-ai-inference -n openshift-ingress
oc delete gatewayclass openshift-default
oc delete hardwareprofile gpu-profile -n redhat-ods-applications

# Remove namespace
oc delete namespace demo-llm
```
