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
  --machine-type=e2-standard-4 \
  --enable-autoprovisioning \
  --min-cpu 1 --max-cpu 200 \
  --min-memory 1 --max-memory 1000 \
  --min-accelerator type=nvidia-l4,count=0 \
  --max-accelerator type=nvidia-l4,count=8 \
  --min-accelerator type=nvidia-rtx-pro-6000,count=0 \
  --max-accelerator type=nvidia-rtx-pro-6000,count=8

echo "Cluster created successfully."
