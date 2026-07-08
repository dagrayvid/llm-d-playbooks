# Chapter 08: Deploy and Benchmark

This chapter covers deploying llm-d and measuring its performance. Each deployment mode has its own self-contained sub-guide with deployment manifests, benchmark tooling, and an optional baseline comparison.

## Prerequisites

- Cluster with GPU nodes available
- llm-d dependencies installed ([Chapter 03](../03-llm-d-dependencies/))
- GPU operator running and validated ([Chapter 06](../06-validate-gpu-readiness/))
- For P/D disaggregation: RDMA networking configured and validated ([Chapter 05](../05-ocp-accelerator-operators/), [Chapter 07](../07-rdma-validation/))

## Deployment Modes

| Mode | Guide | Description | RDMA Required |
|------|-------|-------------|---------------|
| Intelligent inference | [intelligent-inference-scheduler/](intelligent-inference-scheduler/) | Prefix-cache-aware routing with EPP | No |
| P/D disaggregation | *Coming soon* | Separate prefill and decode onto different pods | Yes |

Future modes (WideEP, batch, flow control) will be added as they become available.

## How Each Guide is Structured

Each sub-guide follows the same pattern:

1. **(Optional) Deploy vanilla vLLM baseline** — round-robin load balancing, no intelligent routing. Benchmark it to establish a performance baseline.
2. **Deploy llm-d** in the chosen mode
3. **Benchmark** — measure throughput, latency, and cache efficiency
4. **(Optional) Compare results** — side-by-side analysis vs the baseline

The baseline steps are optional. If you just want to deploy and measure performance without a comparison, skip directly to the llm-d deployment step.

> llm-d **builds on** vLLM — it is not an alternative. vLLM provides the model-serving engine, and llm-d adds intelligent request routing, KV cache-aware scheduling, and prefill/decode disaggregation on top. The vanilla vLLM baseline uses round-robin load balancing to demonstrate the value of llm-d's scheduling features.
