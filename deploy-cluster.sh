#!/bin/bash
set -e

CLUSTER_NAME="ducdo-gke-ig-ubb"
ZONE="us-west1-a"

echo "Creating GKE Cluster: $CLUSTER_NAME in $ZONE"
gcloud container clusters create $CLUSTER_NAME \
  --zone $ZONE \
  --release-channel "rapid" \
  --gateway-api=standard \
  --num-nodes=2 \
  --machine-type=e2-standard-4

echo "Cluster created successfully."
