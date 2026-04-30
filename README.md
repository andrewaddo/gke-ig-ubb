# GKE Inference Gateway: Active-Active Heterogeneous GPU Demo

This demo showcases GKE Inference Gateway's ability to intelligently route requests across heterogeneous GPU pools (NVIDIA L4 and NVIDIA RTX 6000/G4 Blackwell) using a request-based "In-Flight" balancing mode, while scaling independently based on native GPU metrics.

## Architecture

- **Unified Endpoint:** A single Kubernetes Service (`triton-svc`) targets both L4 and G4 deployments via GKE Gateway.
- **Intelligent Routing:** `GCPBackendPolicy` uses `balancingMode: IN_FLIGHT`. This ensures requests are distributed to pods based on their active concurrent request count, naturally balancing load between different hardware types.
- **Native GPU Autoscaling:** Independent HPAs scale the L4 and G4 deployments using GKE's native `AutoscalingMetric` resource, which directly scrapes Triton's `nv_gpu_utilization` metric without needing external adapters.
- **Node Auto-Provisioning (NAP):** Automatically provisions the required GPU nodes (L4 or G4) as the deployments scale up.

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

---

## Running the Demo

### 1. Deploy the Cluster & Workloads
```bash
./deploy-cluster.sh
kubectl apply -f manifests/01-triton-workloads.yaml \
              -f manifests/02-triton-hpas.yaml \
              -f manifests/13-unified-in-flight.yaml
```

### 2. Generate the Load Test Payload
Create the heavy payload locally inside a testing pod (e.g., an Ubuntu `perf-client`):
```bash
python3 -c "import json; print(json.dumps({'inputs': [{'name': 'INPUT__0', 'shape': [1, 4096], 'datatype': 'FP32', 'data': [0.0]*4096}]}))" > payload.json
```

### 3. Run the Sustained Load Script
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

### 4. Verify Active-Active Routing & Scaling
```bash
# Watch the HPA react to nv_gpu_utilization
kubectl get hpa -w

# Check Triton's internal metrics
kubectl exec <POD_NAME> -c triton -- curl -s localhost:8002/metrics | grep nv_gpu_utilization
```
