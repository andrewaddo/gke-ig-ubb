#!/bin/bash
# ==============================================================================
# REAL-TIME QUEUE MONITOR
# Continuously queries the pending request queue depth for all Triton pods.
# ==============================================================================

# Get pod IPs dynamically
L4_IP=$(kubectl get pods -n default -l app=triton-recml,gpu=l4 -o jsonpath='{.items[0].status.podIP}')
G4_1_IP=$(kubectl get pods -n default -l app=triton-recml,gpu=g4 -o jsonpath='{.items[0].status.podIP}')
G4_2_IP=$(kubectl get pods -n default -l app=triton-recml,gpu=g4 -o jsonpath='{.items[1].status.podIP}')

echo "Monitoring Queue Depths..."
echo "Time | L4 Queue | G4-1 Queue | G4-2 Queue"
echo "-----------------------------------------"

while true; do
  L4_Q=$(kubectl exec perf-client -- curl -s $L4_IP:8002/metrics | grep "nv_inference_pending_request_count{model=\"recml-model\"" | awk '{print $2}')
  G4_1_Q=$(kubectl exec perf-client -- curl -s $G4_1_IP:8002/metrics | grep "nv_inference_pending_request_count{model=\"recml-model\"" | awk '{print $2}')
  G4_2_Q=$(kubectl exec perf-client -- curl -s $G4_2_IP:8002/metrics | grep "nv_inference_pending_request_count{model=\"recml-model\"" | awk '{print $2}')
  
  TIME=$(date +%H:%M:%S)
  
  # Only print if there is active load (queues > 0) to avoid spamming the console with zeros
  if [[ "$L4_Q" != "0" || "$G4_1_Q" != "0" || "$G4_2_Q" != "0" ]]; then
    printf "%s | %-8s | %-10s | %-10s\n" "$TIME" "$L4_Q" "$G4_1_Q" "$G4_2_Q"
  fi
  
  sleep 0.2
done
