#!/bin/bash
# ==============================================================================
# SUSTAINED LOAD TEST FOR HPA TRIGGER
# Runs continuous, batched requests to generate sustained GPU utilization.
# Press Ctrl+C to stop.
# ==============================================================================

GATEWAY_IP=$(kubectl get gateway triton-inference-gateway -o jsonpath='{.status.addresses[0].value}')
echo "Starting sustained load test against Gateway: $GATEWAY_IP"
echo "Press Ctrl+C to terminate."

# Run in an infinite loop
while true; do
  echo "Sending firehose batch of 100 requests..."
  for i in $(seq 1 100); do
    kubectl exec perf-client -- curl -s -o /dev/null -w "%{http_code}" -X POST http://$GATEWAY_IP:80/v2/models/recml-model/infer \
      -H "Content-Type: application/json" \
      -d @/tmp/universal_payload.json &
  done
  
  # Small sleep to allow the perf-client to manage its process table, but NO 'wait'
  sleep 0.1
  echo ""
done
