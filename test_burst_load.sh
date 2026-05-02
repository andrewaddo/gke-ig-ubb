#!/bin/bash
# ==============================================================================
# INSTANTANEOUS BURST TEST
# Fires a massive, instantaneous block of requests to overwhelm the queues.
# ==============================================================================

GATEWAY_IP=$(kubectl get gateway triton-inference-gateway -o jsonpath='{.status.addresses[0].value}')
echo "Sending 200 instantaneous requests to Gateway: $GATEWAY_IP"

for i in {1..200}; do
  kubectl exec perf-client -- curl -s -o /dev/null -w "%{http_code}" -X POST http://$GATEWAY_IP:80/v2/models/recml-model/infer \
    -H "Content-Type: application/json" \
    -d @/tmp/universal_payload.json &
done

wait
echo "Burst Complete."
