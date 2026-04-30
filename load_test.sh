#!/bin/bash
echo "Starting sustained load test..."
GATEWAY_IP=$(kubectl get gateway triton-ubb-gateway -o jsonpath='{.status.addresses[0].value}')

# Run 200 requests, 5 requests per second
for i in $(seq 1 200); do
  kubectl exec perf-client -- curl -s -X POST http://$GATEWAY_IP:80/v2/models/recml-model/infer \
    -H "Content-Type: application/json" \
    -d '{"inputs": [{"name": "dense_x__0", "shape": [1, 13], "datatype": "FP32", "data": [0,0,0,0,0,0,0,0,0,0,0,0,0]}, {"name": "sparse_x__1", "shape": [1, 26], "datatype": "INT64", "data": [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]}]}' > /dev/null &
  sleep 0.2
done
wait
echo "Load test complete."
