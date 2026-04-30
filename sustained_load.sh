#!/bin/bash
GATEWAY_IP=$(kubectl get gateway triton-ubb-gateway -o jsonpath='{.status.addresses[0].value}')
echo "Sending 4 requests per second for 120 seconds..."
for i in $(seq 1 120); do
  # Send 4 requests in parallel every second
  for j in $(seq 1 4); do
    kubectl exec perf-client -- curl -s -o /dev/null -X POST http://$GATEWAY_IP:80/v2/models/recml-model/infer \
      -H "Content-Type: application/json" \
      -d '{"inputs": [{"name": "dense_x__0", "shape": [1, 13], "datatype": "FP32", "data": [0,0,0,0,0,0,0,0,0,0,0,0,0]}, {"name": "sparse_x__1", "shape": [1, 26], "datatype": "INT64", "data": [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]}]}' &
  done
  sleep 1
  echo -n "."
done
wait
echo -e "\nLoad test finished."
