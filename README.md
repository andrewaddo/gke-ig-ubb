# GKE Inference Gateway: Active-Active Heterogeneous GPU Demo

This demo showcases GKE Inference Gateway's ability to intelligently route requests across heterogeneous GPU pools (NVIDIA L4 and NVIDIA RTX 6000/G4 Blackwell) using a request-based "In-Flight" balancing mode, while scaling independently based on native GPU metrics.

## Architecture

```mermaid
graph TD
    Client([Client / Load Test]) -->|HTTP POST| Gateway[GKE Inference Gateway]
    Gateway <-->|gRPC ext-proc| EPP[Endpoint Picker sidecar]
    EPP -.->|Calculates queue-scorer| RoutingDecision{Routing Decision}
    RoutingDecision -->|Forward Request| Pool[InferencePool: unified-recml-pool]
    
    subgraph Heterogeneous GPU Pool
        Pool -->|Route| L4[Triton Pod: NVIDIA L4]
        Pool -->|Route| G4_1[Triton Pod: NVIDIA G4 / RTX 6000]
        Pool -->|Route| G4_2[Triton Pod: NVIDIA G4 / RTX 6000]
    end
```

- **Unified Endpoint:** A single Kubernetes Service (`triton-svc`) targets both L4 and G4 deployments via GKE Gateway.
- **Intelligent Routing:** The Gateway uses an `ext-proc` sidecar called the **Endpoint Picker (EPP)**. The EPP is configured with the `queue-scorer` plugin, which evaluates the active request queue depth on every individual pod to naturally balance load between the fast G4s and slower L4s.
- **Native GPU Autoscaling:** Independent HPAs scale the L4 deployments using GKE's native `AutoscalingMetric` resource, which directly scrapes Triton's `nv_gpu_utilization` metric without needing external adapters. Given the feature is not supported yet for G4, we use the traditional approach of **custom metric** instead for G4.
- **Dedicated Autoscaling Node Pools:** The cluster utilizes explicitly defined, dedicated node pools for L4 and G4 hardware. These pools are configured to auto-scale from 0 to 8 nodes independently based on HPA pod demands.

---

## Design Rationale: GKE Inference Gateway vs. standard UBB

For this heterogeneous GPU balancing demo, we evaluated two primary routing strategies. While standard **Utilization-Based Balancing (UBB)** (using a `GCPBackendPolicy`) is easier to configure, **GKE Inference Gateway** was chosen as the superior architectural path for the following reasons:

| Feature | standard GKE Gateway + UBB | GKE Inference Gateway (GKE IG) |
| :--- | :--- | :--- |
| **Granularity** | **Zonal (NEG):** Balances based on the average utilization of a zone. | **Per-Pod:** Scrapes and makes decisions based on individual pod state. |
| **Routing Logic** | **Metric-Based:** Relies on GCLB control plane aggregation (10-30s delay). | **Request-Based:** Per-request gRPC call (ext-proc) for millisecond precision via `queue-scorer`. |
| **Telemetry** | **Cloud Monitoring:** Metrics must be exported to and read from GCP APIs. | **Direct Scrape:** Endpoint Picker (EPP) tracks in-flight request state directly. |
| **Heterogeneous Fit** | **Reactive:** Adjusts as it sees queues back up over time. | **Proactive:** Instantly shifts traffic to faster pods (G4) as soon as L4s show load. |

### Conclusion
GKE Inference Gateway provides the **high-precision, state-aware routing** necessary to exploit the 14x performance difference between our L4 and G4 GPUs. By using a custom-configured Endpoint Picker to monitor Triton metrics, we achieve near-instantaneous balancing that is not possible with the standard asynchronous metric aggregation used by UBB.

---

## Implementation Detail: Triton (RecML) vs. vLLM (LLM)

A significant finding during the implementation of the GKE Inference Gateway was the default behavior of the **Endpoint Picker (EPP)**. 

### The Challenge
By default, the GKE Inference Gateway EPP is optimized for **Large Language Models (LLMs)** using the **OpenAI API specification** (e.g., vLLM). It expects a JSON request body containing a `prompt` or `messages` field, which it parses to enable advanced features like Prefix Cache Aware Routing.

Our **Triton RecML** workload uses the **KServe v2 / Triton API**, which sends a payload containing an `inputs` array instead of a `prompt`. This caused the EPP to return a `400 Bad Request` as it failed to find the expected LLM metadata.

### The Solution: Universal Payload Workaround
Instead of attempting to configure a custom passthrough parser in the EPP (which can be unstable in v1.4.0), we implemented a "Universal Payload" workaround. We wrap the standard Triton `inputs` tensor data alongside dummy `model` and `prompt` fields. 

The EPP successfully parses the dummy OpenAI fields and routes the request, while the underlying Triton pod ignores the extraneous data and processes the `inputs` array natively.

```json
{
  "model": "recml-model",
  "prompt": "dummy",
  "inputs": [ { "name": "INPUT__0", "shape": [1, 4096], "datatype": "FP32", "data": [0.0] } ]
}
```

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
    *   Due to the Gateway splitting traffic, the slower **L4 pods saturated their GPU utilization (100%)** quickly. This correctly triggered the HPA to scale the L4 deployment.
    *   Conversely, the **G4 pods processed requests so quickly (18ms) that their GPU utilization remained low**, requiring significantly higher sustained concurrency to trigger a scale-up.

### Routing Fact: Active Queue-Scorer Balancing
Based on our verified load tests, the Gateway utilizes the `queue-scorer` plugin via the Endpoint Picker (EPP) to intelligently route traffic across heterogeneous hardware:
*   **The Logic:** The EPP actively scrapes the `nv_inference_pending_request_count` metric from Triton pods on port `8080` to determine the exact number of requests waiting in the queue.
*   **The Throughput Effect:** Because the G4 Blackwell GPUs process requests in ~18ms, they drain their queues almost instantly. The EPP observes this queue drop and continually routes more traffic to them.
*   **The L4 Backlog:** Because the L4 GPUs process at ~260ms, their queues stay populated much longer. The `queue-scorer` detects the higher pending request count and naturally throttles new traffic to the L4s to prevent them from becoming overwhelmed.
*   **The Decision:** In a typical sustained load scenario, the EPP perfectly equalizes the queue depths across all pods (e.g., maintaining 150 pending requests per pod). To maintain this equilibrium, the Gateway dynamically routes **~14x more requests to the G4 pool** than the L4 pool, directly reflecting the underlying hardware performance differential without requiring hardcoded capacities.

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

3. **Hybrid Custom Metrics Architecture:**
   * *Issue:* Attempting to use the new Native Custom Metrics (`autoscaling.gke.io/v1beta1`) across the entire cluster failed because the backend Google Cloud aggregation pipeline could not process metrics from the newer G4 hardware, leaving the HPA stuck in `<unknown>`.
   * *Fix:* We implemented a Hybrid Metrics Architecture. The L4 hardware scales using the fast, agentless Native pipeline, while the G4 hardware falls back to traditional Google Managed Prometheus (GMP) combined with the `custom-metrics-stackdriver-adapter` to ensure scaling works reliably across the heterogeneous pools.

4. **Gateway/Pod Timeout Mismatch (The "Ghost Request" Loop):**
   * *Issue:* The L4 queue stayed stuck at 600+ even when the Gateway "thought" it was empty.
   * *Root Cause:* The Gateway's default timeout (30s) was shorter than Triton's processing time for a deep queue. When the Gateway timed out, it dropped the connection to the client and decremented its "In-Flight" counter (making the pod look free to the Endpoint Picker). However, Triton kept the request alive in its internal queue, leading to the pod becoming overwhelmed with "ghost" traffic.
   * *Fix:* We configured Triton's `config.pbtxt` to enforce a hard internal timeout of **29 seconds** (`default_timeout_microseconds: 29000000` with `timeout_action: REJECT`).
   * *Result:* By forcing Triton to reject pending requests slightly *before* the Gateway's 30-second connection timeout, we ensure the Gateway and EPP are always cleanly notified of failures. This eliminates the Ghost Request loop natively.

5. **EPP Metric Scraping for Triton (v1.4.0 Data Layer Overhaul):**
   * *Issue:* The Gateway API Inference Extension `v1.4.0` deprecated the old metric scraping CLI flags and introduced a new `dataLayer` plugin system. However, the EPP defaults to scraping vLLM metrics (`vllm:num_requests_waiting`), which caused our `queue-scorer` to always see a queue depth of `0` for Triton pods, causing it to fall back to round-robin routing.
   * *Fix:* We updated the Helm values to forcefully load the new `model-server-protocol-metrics` data layer using the `EndpointPickerConfig` schema (`v1alpha1`). We mapped the `vllm` queued requests spec to Triton's `nv_inference_pending_request_count` while leaving the `modelServerType` as `vllm` to bypass a bug in the Helm templates that injects crashing deprecated flags. We also had to re-add the deprecated `--model-server-metrics-port=8080` CLI flag, as the v1.4.0 datastore internally still relies on it to find the metrics port if it differs from the inference port.
   * *Result:* The EPP successfully scrapes the Triton metrics on port 8080 and accurately calculates queue scores, enabling the 14x traffic skew towards the G4 nodes.

---

### 1. Deploy the Cluster & Workloads
```bash
./deploy-cluster.sh

# Deploy Triton pods, L4 Native HPA, and G4 GMP HPA
kubectl apply -f manifests/01-triton-workloads-fast.yaml \
              -f manifests/02-triton-hpas.yaml \
              -f manifests/03-autoscaling-metrics.yaml \
              -f manifests/04-g4-podmonitoring.yaml

# Install the Custom Metrics Stackdriver Adapter (Required for G4 GMP metrics)
kubectl apply -f https://raw.githubusercontent.com/GoogleCloudPlatform/k8s-stackdriver/master/custom-metrics-stackdriver-adapter/deploy/production/adapter_new_resource_model.yaml
```

### 2. Deploy the Unified InferencePool via Helm
```bash
helm install unified-recml-pool oci://registry.k8s.io/gateway-api-inference-extension/charts/inferencepool \
  --version v1.4.0 \
  -f helm-values.yaml

# Apply the HealthCheckPolicy override to use Triton's /v2/health/ready endpoint
kubectl apply -f manifests/10-healthcheck-override.yaml
```

### 3. Deploy Gateway and HTTPRoute
```bash
kubectl apply -f manifests/13-inference-gateway.yaml
```

### 4. Create Testing Pod and Generate Payload (Manual Testing Approach)

We utilize two distinct testing approaches in this project:

1.  **Ephemeral Jump Box (`perf-client`):** An ad-hoc pod used for simple connectivity checks, manual `curl` commands, and small burst testing via shell scripts (e.g., `test_burst_load.sh`, `monitor_queues.sh`). It is created on the fly and is not managed by a permanent YAML manifest.
2.  **Distributed Locust Swarm:** A professional load testing suite used for sustained, high-concurrency testing. This approach deploys 15 pods inside the cluster, simulating thousands of concurrent users.

**To set up the `perf-client` for manual testing:**

```bash
# Deploy an Ubuntu testing pod (curlimages/curl is missing required utilities)
kubectl run perf-client --image=ubuntu --command -- sleep infinity
kubectl wait --for=condition=Ready pod/perf-client --timeout=60s
kubectl exec perf-client -- apt-get update
kubectl exec perf-client -- apt-get install -y curl

# Generate the "Universal Payload" and copy it to the pod
python3 -c "import json; print(json.dumps({'model': 'recml-model', 'prompt': 'dummy', 'inputs': [{'name': 'INPUT__0', 'shape': [1, 4096], 'datatype': 'FP32', 'data': [0.0]*4096}]}))" > universal_payload.json
kubectl cp universal_payload.json perf-client:/tmp/universal_payload.json
```

### 5. Run the Load Tests

> [!WARNING]
> **Avoid High-Concurrency Testing via `perf-client`:** Do not use the `perf-client` or local bash scripts (like `test_sustained_load.sh`) for high-concurrency testing. Spawning hundreds of background `kubectl exec` processes will overwhelm the pod's connection limits and your local machine's CPU, causing 504 timeouts and system hangs. Use the **Distributed Locust Swarm** instead.

#### Simulation 1: The Hardware Reality
This test proves that the Gateway protects the slower L4 pod by shifting 99.9% of traffic to the G4 hardware.

1. **Deploy the Swarm:**
   ```bash
   ./start_locust_test.sh
   ```
2. **Monitor Queues:**
   ```bash
   ./monitor_queue_depth.sh
   ```
3. **Observation:** You will see the L4 queue build up to ~500, while the G4 queue stays at 0 (clearing requests faster than the network can deliver them).

#### ⚠️ Understanding Locust Request Rates
If you observe the total requests per second (RPS) dropping significantly during a load test, this is expected behavior when backend queues build up. 
Locust simulates concurrent users **synchronously**. Each virtual user sends a request and *waits* for the response before sending the next one. If half of your simulated users are routed to slower L4 pods with deep queues, those users will hang until Triton responds or times out (up to 29 seconds). This bottlenecking reduces the overall RPS of the swarm, as users cannot send new requests while they are blocked waiting.

#### 🛑 Stop the Load Test
To stop the Locust swarm and allow the pods to scale down, delete the resources using the manifest file:
```bash
kubectl delete -f manifests/15-locust-swarm.yaml
```

---
### 6. Verify Active-Active Routing & Scaling
```bash
# Watch the HPA react to nv_gpu_utilization
kubectl get hpa -w

# Check Triton's internal metrics
kubectl exec <POD_NAME> -c triton -- curl -s localhost:8002/metrics | grep nv_gpu_utilization
```
### Troubleshooting GKE Native Custom Metrics (HPA `<unknown>`)
If an HPA shows `<unknown>` for the target metric (e.g., `autoscaling.gke.io|l4-gpu-util|nv_gpu_utilization`), it indicates a break in the "data bridge" between the pod and the GKE control plane.

**Common Causes:**
1.  **Metric Agent Stream Error:** Check the logs of the `gke-metrics-agent` for `reading from stream failed: EOF`. This indicates the node has lost its handshake with the GKE regional metrics sink (UAS).
2.  **Registration Cache Lag:** After multiple pod restarts or manifest changes, the GKE control plane may take **10-15 minutes** to re-register the new Pod IPs and map them to the `AutoscalingMetric` resource.
3.  **Stale Metric Descriptor:** The `AutoscalingMetric` resource can become "zombied" if the pod selector matches multiple terminating/pending pods during a rolling update.

**To fix this:**
1.  **Restart the Agent:** Identify the node the pod is running on and delete the `gke-metrics-agent` pod on that specific node to force a fresh telemetry discovery.
    ```bash
    kubectl delete pod -n kube-system <agent-pod-name>
    ```
2.  **Hard Reset Registration:** If the restart fails, delete and recreate the `AutoscalingMetric` resource to flush the GKE control plane cache.
    ```bash
    kubectl delete autoscalingmetric l4-gpu-util
    kubectl apply -f manifests/03-autoscaling-metrics.yaml
    ```
3.  **The "Patience" Rule:** Allow at least **15 minutes** of sustained GPU load before declaring the HPA broken. The Native GKE pipeline prioritizes efficiency over high-frequency polling.

### Hybrid Metrics Architecture (L4 vs G4)
During testing, we discovered that the GKE Native Custom Metrics pipeline (`autoscaling.gke.io/v1beta1`) consistently failed to aggregate metrics from the newer NVIDIA RTX 6000 (G4) instances in this environment, leaving the G4 HPA in a permanent `<unknown>` state.

To unblock the demo, we implemented a **Hybrid Metrics Architecture**:

```mermaid
graph TD
    subgraph L4 Architecture Native Custom Metrics
        L4_Pod[Triton L4 Pod] -->|Scraped by| GKE_Agent[gke-metrics-agent]
        GKE_Agent -->|autoscaling.gke.io| K8s_API_1[Kubernetes API]
        K8s_API_1 -->|Scale| HPA_L4[L4 HPA]
    end

    subgraph G4 Architecture GMP + Stackdriver Adapter
        G4_Pod[Triton G4 Pod] -->|Scraped by| GMP[Google Managed Prometheus]
        GMP -->|Export| CloudMon[Cloud Monitoring]
        CloudMon -->|Fetch| Adapter[Stackdriver Adapter]
        Adapter -->|external.metrics.k8s.io| K8s_API_2[Kubernetes API]
        K8s_API_2 -->|Scale| HPA_G4[G4 HPA]
    end
```

*   **L4 Pods:** Continue to use the near-instantaneous GKE Native Custom Metrics pipeline (`AutoscalingMetric`).
*   **G4 Pods:** Use the traditional Google Managed Prometheus (GMP) pipeline. A `PodMonitoring` resource instructs GMP to scrape the G4 pod, and the `custom-metrics-stackdriver-adapter` translates the Cloud Monitoring data back into the Kubernetes API (`prometheus.googleapis.com|nv_gpu_utilization|gauge`) for the HPA to read.

This hybrid approach ensures both hardware pools successfully auto-scale based on their actual GPU utilization.


## **Notes**

### Image Streaming logs

```bash
# Pod pulled the images in seconds and started immediately
Normal   Pulling                  16m                kubelet                  spec.initContainers{generate-model}: Pulling image "us-west1-docker.pkg.dev/gpu-launchpad-playground/triton-images/pytorch:25.05-py3"
  Normal   Pulled                   16m                kubelet                  spec.initContainers{generate-model}: Successfully pulled image "us-west1-docker.pkg.dev/gpu-launchpad-playground/triton-images/pytorch:25.05-py3" in 3.192s (3.192s including waiting). Image size: 12499632379 bytes.
  Normal   Created                  16m                kubelet                  spec.initContainers{generate-model}: Container created
  Normal   Started                  16m                kubelet                  spec.initContainers{generate-model}: Container started
  Normal   Pulling                  15m                kubelet                  spec.containers{triton}: Pulling image "us-west1-docker.pkg.dev/gpu-launchpad-playground/triton-images/tritonserver:25.05-py3"
  Normal   Pulled                   15m                kubelet                  spec.containers{triton}: Successfully pulled image "us-west1-docker.pkg.dev/gpu-launchpad-playground/triton-images/tritonserver:25.05-py3" in 2.234s (2.234s including waiting). Image size: 11729049391 bytes.
  Normal   Created                  15m                kubelet                  spec.containers{triton}: Container created
  Normal   Started                  15m                kubelet                  spec.containers{triton}: Container started
  Normal   LoadBalancerNegReady     15m                neg-readiness-reflector  Pod has become Healthy in NEG "Key{\"k8s1-49691aaf-default-unified-recml-pool-ips-d243-5432-b58739a6\", zone: \"us-west1-a\"}" attached to BackendService "Key{\"gkegw1-h5cw-defaul-unified-recml-pool-ips-d2-54321-6qvws6sxbhfq\", region: \"us-west1\"}". Marking condition "cloud.google.com/load-balancer-neg-ready" to True.
```

### Test script automatically detected new pods and updated the view

```bash
$ ./monitor_queue_depth.sh 
==========================================================================
Legend:
  Q : Current Queue Depth (Pending Requests waiting in Triton)
  R : Total Routed (+Requests sent to this pod since last tick)
  S : Successes (+Requests completed successfully since last tick)
  F : Failures (+Requests REJECTED due to timeout since last tick)
==========================================================================


--- Pod topology changed. Updating monitoring view ---
Time      | ct6hl(g4)                | ms8br(l4)               
---------+-------------------------+-------------------------
19:56:03  | Q:267 R:+0 (S:+0 F:+0)   | Q:270 R:+0 (S:+0 F:+0)  
19:56:12  | Q:298 R:+455 (S:+455 F:+0) | Q:299 R:+32 (S:+32 F:+0)
19:56:20  | Q:297 R:+456 (S:+456 F:+0) | Q:299 R:+32 (S:+32 F:+0)
```

```bash
19:59:35  | Q:298 R:+452 (S:+452 F:+0) | Q:299 R:+173 (S:+32 F:+141)
19:59:43  | Q:296 R:+452 (S:+452 F:+0) | Q:298 R:+33 (S:+32 F:+1)

--- Pod topology changed. Updating monitoring view ---
Time      | ct6hl(g4)                | ms8br(l4)                | r8l6h(l4)               
---------+-------------------------+-------------------------+-------------------------
19:59:52  | Q:297 R:+0 (S:+0 F:+0)   | Q:299 R:+0 (S:+0 F:+0)   | Q:0 R:+0 (S:+0 F:+0)    
20:00:00  | Q:265 R:+464 (S:+464 F:+0) | Q:293 R:+219 (S:+33 F:+186) | Q:39 R:+0 (S:+0 F:+0)   
20:00:09  | Q:169 R:+466 (S:+466 F:+0) | Q:258 R:+35 (S:+32 F:+3) | Q:170 R:+30 (S:+30 F:+0)
```

```bash
20:08:47  | Q:196 R:+466 (S:+466 F:+0) | Q:200 R:+124 (S:+33 F:+91) | Q:199 R:+126 (S:+33 F:+93)
20:08:55  | Q:198 R:+463 (S:+463 F:+0) | Q:198 R:+33 (S:+32 F:+1) | Q:199 R:+32 (S:+32 F:+0)

--- Pod topology changed. Updating monitoring view ---
Time      | ct6hl(g4)                | p6fsg(g4)                | ms8br(l4)                | r8l6h(l4)               
---------+-------------------------+-------------------------+-------------------------+-------------------------
20:09:04  | Q:106 R:+0 (S:+0 F:+0)   | Q:109 R:+0 (S:+0 F:+0)   | Q:188 R:+0 (S:+0 F:+0)   | Q:187 R:+0 (S:+0 F:+0)  
20:09:13  | Q:147 R:+473 (S:+473 F:+0) | Q:146 R:+464 (S:+464 F:+0) | Q:150 R:+125 (S:+33 F:+92) | Q:147 R:+124 (S:+33 F:+91)
```