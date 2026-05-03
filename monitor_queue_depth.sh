#!/bin/bash
L4_IP=$(kubectl get pods -n default -l app=triton-recml,gpu=l4 -o jsonpath='{.items[0].status.podIP}')
G4_IP=$(kubectl get pods -n default -l app=triton-recml,gpu=g4 -o jsonpath='{.items[0].status.podIP}')

echo "Time     | L4 Queue | G4 Queue" > /tmp/queue_depth_log.txt
echo "------------------------------" >> /tmp/queue_depth_log.txt

while true; do
  L4_Q=$(kubectl exec perf-client -- curl -s $L4_IP:8002/metrics | awk '/nv_inference_pending_request_count\{/ {print $2}')
  G4_Q=$(kubectl exec perf-client -- curl -s $G4_IP:8002/metrics | awk '/nv_inference_pending_request_count\{/ {print $2}')
  
  if [ -z "$L4_Q" ]; then L4_Q="0"; fi
  if [ -z "$G4_Q" ]; then G4_Q="0"; fi
  
  TIME=$(date +%H:%M:%S)
  printf "%s | %-8s | %-8s\n" "$TIME" "$L4_Q" "$G4_Q" >> /tmp/queue_depth_log.txt
  
  sleep 2
done
