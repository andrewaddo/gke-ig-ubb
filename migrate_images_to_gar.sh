#!/bin/bash
set -e

# Make sure we are authenticated with Artifact Registry
echo "Authenticating with Google Artifact Registry..."
gcloud auth configure-docker us-west1-docker.pkg.dev --quiet

GAR_REPO="us-west1-docker.pkg.dev/gpu-launchpad-playground/triton-images"

echo ""
echo "=== Migrating Triton Server Image ==="
TRITON_IMG="nvcr.io/nvidia/tritonserver@sha256:eab308e1718393bcdd2b795878bcccb4301963b7c9dc5d5774924d681815add1"
GAR_TRITON="$GAR_REPO/tritonserver:25.05-py3"

echo "Pulling $TRITON_IMG (This is ~8GB and will take a few minutes)..."
docker pull --platform linux/amd64 $TRITON_IMG

echo "Tagging for GAR..."
docker tag $TRITON_IMG $GAR_TRITON

echo "Pushing to GAR..."
docker push $GAR_TRITON

echo ""
echo "=== Migrating PyTorch Image ==="
PYTORCH_IMG="nvcr.io/nvidia/pytorch@sha256:c7c5d28173d2a59a050c11d674e375fae29d5c9663965025ccad541cd4b7af1b"
GAR_PYTORCH="$GAR_REPO/pytorch:25.05-py3"

echo "Pulling $PYTORCH_IMG (This is ~12.5GB and will take a few minutes)..."
docker pull --platform linux/amd64 $PYTORCH_IMG

echo "Tagging for GAR..."
docker tag $PYTORCH_IMG $GAR_PYTORCH

echo "Pushing to GAR..."
docker push $GAR_PYTORCH

echo ""
echo "Migration Complete! Images are now in $GAR_REPO"
echo "You can now run ./enable-image-streaming.sh to enable streaming on the cluster."
