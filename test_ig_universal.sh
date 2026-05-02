#!/bin/bash
# ==============================================================================
# IMPORTANT WARNING: GKE INFERENCE GATEWAY PAYLOAD REQUIREMENT
# 
# Do NOT test the Gateway IP with standard Triton payloads (e.g., {"inputs": []}).
# The Endpoint Picker (EPP) defaults to an openai-parser and expects LLM metadata.
# Standard payloads will be rejected with a 400 Bad Request error.
# 
# This script uses the required "Universal Payload" (universal_payload.json) which
# wraps the Triton tensor data alongside dummy `model` and `prompt` fields to 
# successfully pass through the Gateway.
# ==============================================================================

GATEWAY_IP=$(kubectl get gateway triton-inference-gateway -o jsonpath='{.status.addresses[0].value}')
echo "Sending 100 requests to GKE Inference Gateway at $GATEWAY_IP..."
for i in $(seq 1 100); do
  kubectl exec perf-client -- curl -s -o /dev/null -X POST http://$GATEWAY_IP:80/v2/models/recml-model/infer \
    -H "Content-Type: application/json" \
    -d @/tmp/universal_payload.json &
  
  if [ $((i % 10)) -eq 0 ]; then
    sleep 0.5
  fi
done
wait
echo "Done."
