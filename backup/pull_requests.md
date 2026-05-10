# Proposed Pull Requests for Gateway API Inference Extension

Based on our integration of standard Triton Inference Server (for non-LLM workloads like Recommender Systems) with GKE Inference Gateway v1.4.0, we identified several friction points. 

Contributing the following changes to the [kubernetes-sigs/gateway-api-inference-extension](https://github.com/kubernetes-sigs/gateway-api-inference-extension) repository would significantly improve its compatibility with general ML workloads.

---

## PR 1: Add Native Metric Mapping for Standard Triton

**The Problem:**
Currently, the Endpoint Picker (EPP) auto-populates metric extraction mappings only for `vllm`, `sglang`, and `triton-tensorrt-llm`. Users running standard Triton (PyTorch, TensorFlow, etc.) must "trick" the EPP by setting `modelServerType: vllm` and writing complex `EndpointPickerConfig` overrides to map the queue metrics. If they use `modelServerType: custom`, metric scraping is disabled entirely, breaking the `queue-scorer`.

**The Proposed Change:**
1.  **CRD Update:** Update the `modelServerType` enum in the `InferencePool` CRD to officially accept `triton` (in addition to `triton-tensorrt-llm`).
2.  **Go Codebase:** In `pkg/epp/framework/plugins/datalayer/extractor/metrics/factories.go`, add a default mapping for standard Triton:
    *   Map `QueuedRequestsSpec` to `"nv_inference_pending_request_count"`
    *   Map `RunningRequestsSpec` to `"nv_inference_exec_count"`
3.  **Benefit:** Users can simply declare `modelServerType: triton` and the `queue-scorer` will work out-of-the-box for standard ML models.

---

## PR 2: Fix Helm Chart Deprecation Bug for `triton-tensorrt-llm`

**The Problem:**
In v1.4.0, the metric extraction architecture was overhauled (introducing the `dataLayer` feature gate and `model-server-protocol-metrics` plugin). Legacy CLI flags like `--total-queued-requests-metric` were explicitly deprecated. However, the Helm chart templates are out of sync. If a user sets `modelServerType: triton-tensorrt-llm` in their `values.yaml`, the Helm chart injects these deprecated flags into the EPP deployment arguments. The v1.4.0 EPP binary rejects these flags on startup, causing a `CrashLoopBackOff`.

**The Proposed Change:**
1.  **Helm Templates:** Update `manifests/charts/inferencepool/templates/_deployment.yaml`.
2.  **Refactoring:** Remove the logic that injects the legacy CLI metric flags.
3.  **Alignment:** Modify the Helm chart to dynamically generate the correct `EndpointPickerConfig` using the `engineConfigs` block, aligning the deployment with the new v1.4.0 Data Layer architecture.

---

## PR 3: Introduce a KServe v2 / Passthrough Payload Parser

**The Problem:**
The EPP routes traffic by inspecting the request payload. By default, it forces all traffic through an `openai-parser` which strictly expects LLM schema fields (`model`, `prompt`, or `messages`). When standard ML workloads send KServe v2 / Triton payloads (which use an `inputs` array), the EPP fails to parse the body and rejects the request with a `400 Bad Request`. We had to wrap standard tensor payloads in dummy OpenAI fields to bypass this.

**The Proposed Change:**
1.  **New Parser:** Introduce a new parser (e.g., `kserve-parser` or `passthrough-parser`) alongside the existing `openai-parser` in the Go codebase.
2.  **Configuration:** Allow users to specify which parser the EPP should use via the `InferencePool` annotations or the `EndpointPickerConfig`.
3.  **Benefit:** Eliminates the need for client-side payload manipulation (the "Universal Payload" workaround), allowing standard ML services to communicate with the Gateway using native API contracts.