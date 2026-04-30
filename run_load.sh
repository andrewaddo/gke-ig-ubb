#!/bin/bash
GATEWAY_IP=10.138.0.111
PAYLOAD_FILE="input_payload.json"

# Create the payload file once
python3 -c "import json; print(json.dumps({'inputs': [{'name': 'INPUT__0', 'shape': [1, 1024], 'datatype': 'FP32', 'data': [0.0]*1024}]}))" > $PAYLOAD_FILE

echo "Starting sustained load test (1000 requests)..."
for i in $(seq 1 1000); do
  # Copy the payload file into the pod once so we don't pass massive strings
  if [ $i -eq 1 ]; then
    kubectl cp $PAYLOAD_FILE perf-client:/tmp/payload.json
  fi

  kubectl exec perf-client -- curl -s -o /dev/null -X POST http://$GATEWAY_IP:80/v2/models/recml-model/infer \
    -H "Content-Type: application/json" \
    -d @/tmp/payload.json &
  
  if [ $((i % 20)) -eq 0 ]; then
    echo -n "."
    sleep 1
  fi
done
wait
echo -e "\nLoad test finished."
