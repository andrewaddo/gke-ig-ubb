# GKE Inference Gateway: Active-Active Heterogeneous GPU Demo

This demo showcases GKE Inference Gateway's ability to intelligently route requests across heterogeneous GPU pools (NVIDIA L4 and NVIDIA RTX 6000/G4 Blackwell) using a request-based "In-Flight" balancing mode, while scaling independently based on native GPU metrics.

## Architecture

- **Unified Endpoint:** A single Kubernetes Service (`triton-svc`) targets both L4 and G4 deployments via GKE Gateway.
- **Intelligent Routing:** `GCPBackendPolicy` uses `balancingMode: IN_FLIGHT`. This ensures requests are distributed to pods based on their active concurrent request count, naturally balancing load between different hardware types.
- **Native GPU Autoscaling:** Independent HPAs scale the L4 and G4 deployments using GKE's native `AutoscalingMetric` resource, which directly scrapes Triton's `nv_gpu_utilization` metric without needing external adapters.
- **Node Auto-Provisioning (NAP):** Automatically provisions the required GPU nodes (L4 or G4) as the deployments scale up.

---

## Design Rationale: GKE Inference Gateway vs. UBB

For this heterogeneous GPU balancing demo, we evaluated two primary routing strategies. While standard **Utilization-Based Balancing (UBB)** is stable and easier to configure, **GKE Inference Gateway** was chosen as the superior architectural path for the following reasons:

| Feature | standard GKE Gateway + UBB | GKE Inference Gateway (GKE IG) |
| :--- | :--- | :--- |
| **Granularity** | **Zonal (NEG):** Balances based on the average utilization of a zone. | **Per-Pod:** Scrapes and makes decisions based on individual pod state. |
| **Routing Logic** | **Metric-Based:** Relies on GCLB control plane aggregation (10-30s delay). | **Request-Based:** Per-request gRPC call (ext-proc) for millisecond precision. |
| **Telemetry** | **Cloud Monitoring:** Metrics must be exported to and read from GCP APIs. | **Direct Scrape:** Endpoint Picker (EPP) scrapes Triton metrics directly. |
| **Heterogeneous Fit** | **Reactive:** Adjusts as it sees queues back up over time. | **Proactive:** Instantly shifts traffic to faster pods (G4) as soon as L4s show load. |

### Conclusion
GKE Inference Gateway provides the **high-precision, state-aware routing** necessary to exploit the 14x performance difference between our L4 and G4 GPUs. By using a custom-configured Endpoint Picker to monitor Triton metrics, we achieve near-instantaneous balancing that is not possible with the standard asynchronous metric aggregation used by UBB.

---

## Implementation Detail: Triton (RecML) vs. vLLM (LLM)

A significant finding during the implementation of the GKE Inference Gateway was the default behavior of the **Endpoint Picker (EPP)**. 

### The Challenge
By default, the GKE Inference Gateway EPP is optimized for **Large Language Models (LLMs)** using the **OpenAI API specification** (e.g., vLLM). It expects a JSON request body containing a `prompt` or `messages` field, which it parses to enable advanced features like Prefix Cache Aware Routing.

Our **Triton RecML** workload uses the **KServe v2 / Triton API**, which sends a payload containing an `inputs` array instead of a `prompt`. This caused the EPP to return a `400 Bad Request` as it failed to find the expected LLM metadata.

### The Solution: Passthrough Parser
To support non-LLM workloads like Triton RecML, we must explicitly configure the EPP to use the **`passthrough-parser`**. This tells the Inference Gateway to skip body inspection and purely apply scheduling logic (like `LeastRequests`) based on pod health and concurrency.

---


A critical nuance of the GKE Inference Gateway architecture (introduced in GKE 1.34+) is the distinction between what GKE manages and what the user must provide.

**What GKE Manages:**
*   **The CRD Schema:** GKE natively understands `kind: InferencePool` and `kind: InferenceObjective`. You do not need to install these Custom Resource Definitions.
*   **The Gateway Controller:** When the Gateway reads an `HTTPRoute` pointing to an `InferencePool`, it automatically configures the underlying Google Cloud Load Balancer.

**What GKE Does NOT Manage:**
*   **The Endpoint Picker (EPP):** The EPP is the actual "brain" (a gRPC service) that receives `ext-proc` calls from Envoy to make per-request routing decisions. **GKE does not deploy this automatically.** If you create an `InferencePool` without an EPP, traffic will not route.

**The Solution: Helm**
While it is possible to manually write the Deployment, Service, ConfigMap, and RBAC manifests for the EPP, it is highly error-prone due to rapidly changing flags and API versions. The official Google-recommended approach is to use the `gateway-api-inference-extension` Helm chart. 

The Helm chart abstracts this complexity by:
1.  Deploying the correct version of the EPP container.
2.  Generating the `InferencePool` resource.
3.  Automatically wiring the `endpointPickerRef` to the newly created EPP Service.

---

## Key Findings & Performance Metrics

During our load testing, we observed significant differences between the heterogeneous hardware pools executing the same PyTorch "HeavyModel" (4096x4096 matrix multiplication, 1000 iterations):

*   **Inference Latency:**
    *   **NVIDIA L4:** ~262ms per request
    *   **NVIDIA RTX 6000 (G4):** ~18ms per request
    *   *Result:* The Blackwell G4 GPU proved to be approximately **14x faster** for this specific tensor math operation.
*   **Independent HPA Scaling:**
    *   Due to the `IN_FLIGHT` load balancer splitting traffic across both pools, the slower **L4 pods saturated their GPU utilization (100%)** quickly. This correctly triggered the HPA to scale the L4 deployment from 1 to 5 replicas.
    *   Conversely, the **G4 pods processed requests so quickly (18ms) that their GPU utilization remained between 0% and 2%**, well below the 60% HPA threshold. The G4 deployment safely remained at 1 replica.

---

## Lessons Learned & Troubleshooting (What Didn't Work)

1. **CPU Fallback on Blackwell GPUs:**
   * *Issue:* The RTX 6000 G4 pods were initially taking 40+ seconds per inference.
   * *Root Cause:* We were using Triton version `24.01`, which predates native support for the Blackwell architecture. Triton silently fell back to CPU execution.
   * *Fix:* Upgraded the Triton server and PyTorch base images to `25.05-py3`, which includes the necessary CUDA optimizations for Blackwell.

2. **HPA Scaling on CPU for GPU Workloads:**
   * *Issue:* Initial attempts to scale the HPA based on CPU utilization failed (stuck at 0-2%).
   * *Root Cause:* The model execution is entirely offloaded to the GPU. The CPU is only responsible for lightweight HTTP handling.
   * *Fix:* Shifted the scaling metric entirely to GPU utilization.

3. **Custom Metrics Stackdriver Adapter Overhead:**
   * *Issue:* Attempting to use the legacy `custom-metrics-stackdriver-adapter` to fetch DCGM node metrics required complex Workload Identity IAM bindings and often failed to locate the correct metric.
   * *Fix:* We adopted GKE's **New Native Custom Metrics** (`autoscaling.gke.io/v1beta1`). By configuring an `AutoscalingMetric` to directly scrape Triton's `/metrics` endpoint on port 8002 for `nv_gpu_utilization`, we bypassed Cloud Monitoring entirely. The HPA now reads the GPU state in near real-time directly from the pods.

4. **Load Testing Client Saturation (`connection reset by peer`):**
   * *Issue:* Spawning thousands of parallel `curl` background processes in a naive bash script exhausted the `perf-client` pod's connection limits and caused Gateway 504 timeouts.
   * *Fix:* Used a batched load testing script with limited concurrency, utilizing a pre-generated JSON payload file to avoid shell string escaping issues and reduce client-side CPU overhead.

5. **Triton Payload Parsing via Endpoint Picker:**
   * *Issue:* The Endpoint Picker (EPP) defaults to the `openai-parser`, which expects a JSON payload containing `prompt` or `messages`. Standard KServe/Triton requests with only `inputs` are rejected with a `400 Bad Request`.
   * *Fix:* We construct a "Universal Payload" that wraps the standard Triton tensor data alongside dummy `model` and `prompt` fields. This satisfies the EPP's parser, allowing the request to be routed, while Triton ignores the extraneous fields.
   ```json
   {
     "model": "recml-model",
     "prompt": "dummy",
     "inputs": [ { "name": "INPUT__0", "shape": [1, 4096], "datatype": "FP32", "data": [0.0] } ]
   }
   ```

---

## Why GCPBackendPolicy is Omitted

In standard GKE Gateway architectures, a `GCPBackendPolicy` is often used to define the `balancingMode` (e.g., `IN_FLIGHT`). However, in the **GKE Inference Gateway** architecture, this policy is omitted for the following reasons:

1.  **EPP Takeover:** The **Endpoint Picker (EPP)** acts as the real-time "brain" for routing. It intercepts every request and selects the optimal Pod IP based on millisecond-fresh metrics.
2.  **Incompatibility:** Manual `balancingMode` settings in a `GCPBackendPolicy` can conflict with the EPP's intelligent scheduling logic.
3.  **Managed Intelligence:** The Inference Gateway pattern assumes that the EPP is the authoritative source for load balancing decisions, rendering the static configuration in a `GCPBackendPolicy` redundant.

---


### 1. Deploy the Cluster & Workloads
```bash
./deploy-cluster.sh
kubectl apply -f manifests/01-triton-workloads.yaml \
              -f manifests/02-triton-hpas.yaml
```

### 2. Deploy the Unified InferencePool via Helm
```bash
helm install unified-recml-pool oci://registry.k8s.io/gateway-api-inference-extension/charts/inferencepool \
  --version v1.4.0 \
  --set inferencePool.modelServerType=custom \
  --set inferencePool.targetPortNumber=8000 \
  --set inferencePool.modelServers.matchLabels.pool=unified-recml-pool \
  --set provider.name=gke
```

### 3. Deploy Gateway and HTTPRoute
```bash
kubectl apply -f manifests/13-inference-gateway.yaml
```

### 4. Generate the Load Test Payload
Create the heavy payload locally inside a testing pod (e.g., an Ubuntu `perf-client`):
```bash
python3 -c "import json; print(json.dumps({'inputs': [{'name': 'INPUT__0', 'shape': [1, 4096], 'datatype': 'FP32', 'data': [0.0]*4096}]}))" > payload.json
```

### 5. Run the Sustained Load Script
You can use `run_load.sh` or execute this directly to simulate sustained traffic:
```bash
GATEWAY_IP=$(kubectl get gateway triton-ubb-gateway -o jsonpath='{.status.addresses[0].value}')

# Send sustained requests to trigger GPU HPA
for i in $(seq 1 2000); do
  curl -s -o /dev/null -X POST http://$GATEWAY_IP:80/v2/models/recml-model/infer \
    -H "Content-Type: application/json" \
    -d @payload.json &
  
  if [ $((i % 20)) -eq 0 ]; then
    sleep 1 # Paces the test to avoid client-side connection drops
  fi
done
wait
```

### 6. Verify Active-Active Routing & Scaling
```bash
# Watch the HPA react to nv_gpu_utilization
kubectl get hpa -w

# Check Triton's internal metrics
kubectl exec <POD_NAME> -c triton -- curl -s localhost:8002/metrics | grep nv_gpu_utilization
```