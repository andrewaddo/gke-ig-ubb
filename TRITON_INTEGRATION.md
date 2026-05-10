# GKE Inference Gateway: Triton Custom Integration Guide

The GKE Gateway API Inference Extension (specifically the Endpoint Picker / EPP) is heavily optimized out-of-the-box for Large Language Models (LLMs) running on servers like `vLLM` or `Triton-TensorRT-LLM`. 

When integrating a standard **Triton Inference Server** (e.g., for Recommender Systems or standard PyTorch models), the Gateway and EPP will fail by default. This document outlines the precise configuration differences required to make standard Triton work seamlessly with the EPP's `queue-scorer`.

---

## 1. Metric Scraping & Queue-Scorer (The Data Layer Override)
**The Problem:**
To use intelligent routing (`queue-scorer`), the EPP must read the model server's queue depth. By default, it expects vLLM metrics (on port `8000`) or TensorRT-LLM metrics. Standard Triton serves metrics on port `8080` under the name `nv_inference_pending_request_count`. Setting `modelServerType: custom` entirely disables metric routing maps.

**The Triton Configuration:**
You must trick the EPP into using the `vllm` schema, but override the metric data layer to look for Triton's metrics on the correct port. In `v1.4.0`, this requires enabling the experimental `dataLayer` feature gate.

*In `helm-values.yaml`:*
```yaml
inferenceExtension:
  flags:
    # 1. Force the EPP to scrape port 8080 instead of the inference port (8000)
    # Note: Even though this flag throws a deprecation warning in v1.4.0, it is REQUIRED.
    model-server-metrics-port: 8080
  pluginsCustomConfig:
    default-plugins.yaml: |
      apiVersion: inference.networking.x-k8s.io/v1alpha1
      kind: EndpointPickerConfig
      
      # 2. Enable the hidden v1.4.0 dataLayer feature
      featureGates:
        - dataLayer
        
      plugins:
        - name: queue-scorer
          type: queue-scorer
          
        # 3. Explicitly declare the v1.4.0 metrics extractor
        - name: model-server-protocol-metrics
          type: model-server-protocol-metrics
          parameters:
            engineConfigs:
              - name: vllm
                # 4. OVERRIDE the vllm defaults with Triton's specific metric names
                queuedRequestsSpec: "nv_inference_pending_request_count"
                runningRequestsSpec: "nv_inference_exec_count"
                kvUsageSpec: ""
                loraSpec: ""
                cacheInfoSpec: ""
        - name: metrics-data-source
          type: metrics-data-source
      data:
        sources:
          - pluginRef: metrics-data-source
            extractors:
              - pluginRef: model-server-protocol-metrics
      schedulingProfiles:
        - name: default
          plugins:
            - pluginRef: queue-scorer

inferencePool:
  # 5. Leave this as vllm. Do NOT use "custom" or "triton-tensorrt-llm".
  modelServerType: vllm 
  targetPortNumber: 8000
```

---

## 2. Response Parsing (The GZIP Crash)
**The Problem:**
The EPP intercepts the response body from the model server to track completion metrics. Triton compresses responses using `gzip` by default. The EPP (v1.4.0) attempts to unmarshal this binary data (`\x1f`) as plain JSON and enters a crash loop, returning `503 Gateway Timeouts`.

**The Triton Configuration:**
You must configure Triton to ignore the client's `Accept-Encoding: gzip` header.

*In the Triton Deployment args (`manifests/01-triton-workloads-fast.yaml`):*
```yaml
args: 
  - "--allow-grpc=false"
  - "--http-header-forward-pattern=" # Prevents Triton from receiving the GZIP header
```

---

## 3. Payload Compatibility (The OpenAI Parser)
**The Problem:**
The EPP defaults to using an `openai-parser`. If a request arrives without a `model`, `prompt`, or `messages` field, the EPP rejects it with a `400 Bad Request`. Standard Triton API payloads use an `inputs` array.

**The Triton Configuration:**
You must wrap your Triton payload in dummy OpenAI fields. The EPP parses the dummy fields and approves the request, while Triton ignores them and reads the `inputs` array.

*Universal Payload Format:*
```json
{
  "model": "recml-model",
  "prompt": "dummy",
  "inputs": [
    {
      "name": "INPUT__0",
      "shape": [1, 4096],
      "datatype": "FP32",
      "data": [0.0]
    }
  ]
}
```

---

## 4. Timeout Alignment (Ghost Requests)
**The Problem:**
The GKE Gateway has a default request timeout of `30s`. If Triton's queue is deep, requests will wait longer than 30s. The Gateway drops the connection (decrementing its "In-Flight" count), but Triton keeps the request in its queue. The EPP thinks the pod is empty and sends more traffic, burying the pod in "ghost" requests it can never clear.

**The Triton Configuration:**
You must configure a hard timeout inside Triton that is strictly *less* than the Gateway's timeout. 

*In Triton `config.pbtxt`:*
```protobuf
dynamic_batching {
  default_queue_policy {
    # 29 seconds (Gateway is 30s)
    default_timeout_microseconds: 29000000 
    timeout_action: REJECT
    allow_timeout_override: true
  }
}
```
This forces Triton to actively reject the request, cleanly notifying the EPP that the request failed rather than letting it sit invisibly in the queue.
