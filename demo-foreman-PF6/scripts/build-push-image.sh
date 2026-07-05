#!/bin/bash
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

REGISTRY="${REGISTRY:-quay.io/jwerak}"
TAG="${TAG:-latest}"
FOREMAN_SRC="${FOREMAN_SRC:-$HOME/git/foreman}"
IMAGE="${REGISTRY}/foreman:${TAG}"

echo -e "${GREEN}=== Foreman Container Image Builder ===${NC}"
echo -e "Source:   ${FOREMAN_SRC}"
echo -e "Image:    ${IMAGE}"
echo ""

if [ ! -f "${FOREMAN_SRC}/Dockerfile" ]; then
  echo -e "${RED}ERROR: Dockerfile not found at ${FOREMAN_SRC}/Dockerfile${NC}"
  echo "Set FOREMAN_SRC to the Foreman source directory."
  exit 1
fi

echo -e "${YELLOW}Building image...${NC}"
podman build -t "${IMAGE}" -f "${FOREMAN_SRC}/Dockerfile" "${FOREMAN_SRC}"

echo ""
echo -e "${GREEN}Build complete: ${IMAGE}${NC}"
echo ""

if [ "${PUSH:-}" = "true" ] || [ "${1:-}" = "--push" ]; then
  echo -e "${YELLOW}Pushing to ${REGISTRY}...${NC}"
  podman push "${IMAGE}"
  echo -e "${GREEN}Push complete.${NC}"
else
  echo "To push: PUSH=true $0"
  echo "   or:   $0 --push"
fi
