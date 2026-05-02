#!/bin/bash
set -e

CLUSTER_NAME="ducdo-gke-ig-ubb"
ZONE="us-west1-a"

echo "Creating base GKE Cluster: $CLUSTER_NAME in $ZONE"
gcloud container clusters create $CLUSTER_NAME \
  --zone $ZONE \
  --release-channel "rapid" \
  --gateway-api=standard \
  --num-nodes=2 \
  --machine-type=e2-standard-4

echo "Creating dedicated L4 Node Pool (Autoscaling 0-8)"
gcloud container node-pools create l4-pool \
  --cluster $CLUSTER_NAME \
  --zone $ZONE \
  --machine-type g2-standard-8 \
  --accelerator type=nvidia-l4,count=1,gpu-driver-version=latest \
  --enable-autoscaling --min-nodes 0 --max-nodes 8

echo "Creating dedicated G4 Node Pool (Autoscaling 0-8)"
gcloud container node-pools create g4-pool \
  --cluster $CLUSTER_NAME \
  --zone $ZONE \
  --machine-type g4-standard-48 \
  --accelerator type=nvidia-rtx-pro-6000,count=1,gpu-driver-version=latest \
  --enable-autoscaling --min-nodes 0 --max-nodes 8

echo "Cluster and Node Pools created successfully."
