#!/bin/bash
GATEWAY_IP=10.138.0.32
echo "Sending 100 requests to GKE Inference Gateway..."
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
