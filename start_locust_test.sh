#!/bin/bash
# Dynamically fetch the Gateway IP and deploy the Locust swarm

GATEWAY_IP=$(kubectl get gateway triton-inference-gateway -o jsonpath='{.status.addresses[0].value}')

if [ -z "$GATEWAY_IP" ]; then
  echo "Error: Could not find Gateway IP. Is the gateway programmed?"
  exit 1
fi

echo "Found Gateway IP: $GATEWAY_IP"
echo "Deploying Locust Swarm targeting http://$GATEWAY_IP..."

# Replace the hardcoded IP and apply
sed "s|--host http://REPLACE_ME_DYNAMICALLY|--host http://$GATEWAY_IP|g" manifests/15-locust-swarm.yaml | kubectl apply -f -

echo "Locust Swarm deployed successfully."
