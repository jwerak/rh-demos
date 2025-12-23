#!/bin/bash
##
## Build and push container images for the hybrid app demo
##

set -e

# Configuration
REGISTRY="${REGISTRY:-quay.io/jwerak}"
BACKEND_IMAGE="${REGISTRY}/hybrid-app-backend"
FRONTEND_IMAGE="${REGISTRY}/hybrid-app-frontend"
TAG="${TAG:-latest}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Building Hybrid App Container Images${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "Registry: ${YELLOW}${REGISTRY}${NC}"
echo -e "Tag: ${YELLOW}${TAG}${NC}"
echo ""

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_DIR="$(dirname "${SCRIPT_DIR}")"

# Build backend image
echo -e "${GREEN}[1/2] Building backend image...${NC}"
podman build \
    -t "${BACKEND_IMAGE}:${TAG}" \
    -f "${DEMO_DIR}/container-images/backend/Containerfile" \
    "${DEMO_DIR}/container-images/backend/"

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Backend image built successfully${NC}"
else
    echo -e "${RED}✗ Backend image build failed${NC}"
    exit 1
fi

# Build frontend image
echo -e "${GREEN}[2/2] Building frontend image...${NC}"
podman build \
    -t "${FRONTEND_IMAGE}:${TAG}" \
    -f "${DEMO_DIR}/container-images/frontend/Containerfile" \
    "${DEMO_DIR}/container-images/frontend/"

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Frontend image built successfully${NC}"
else
    echo -e "${RED}✗ Frontend image build failed${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Build Summary${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "Backend:  ${YELLOW}${BACKEND_IMAGE}:${TAG}${NC}"
echo -e "Frontend: ${YELLOW}${FRONTEND_IMAGE}:${TAG}${NC}"
echo ""

# Ask if user wants to push
read -p "Do you want to push images to registry? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${GREEN}Pushing images to registry...${NC}"

    echo -e "${GREEN}Pushing backend image...${NC}"
    podman push "${BACKEND_IMAGE}:${TAG}"

    echo -e "${GREEN}Pushing frontend image...${NC}"
    podman push "${FRONTEND_IMAGE}:${TAG}"

    echo -e "${GREEN}✓ Images pushed successfully${NC}"
else
    echo -e "${YELLOW}Skipping push. Images are available locally.${NC}"
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Next Steps${NC}"
echo -e "${GREEN}========================================${NC}"
echo "1. If you pushed images, update the image references in:"
echo "   - k8s/base/backend-deployment.yaml"
echo "   - k8s/base/frontend-deployment.yaml"
echo ""
echo "2. Deploy the application using kustomize:"
echo "   Development: kustomize build k8s/overlays/development | oc apply -f -"
echo "   Production:  kustomize build k8s/overlays/production | oc apply -f -"
echo ""
