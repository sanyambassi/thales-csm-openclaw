#!/usr/bin/env bash
#
# Builds the OpenClaw + CipherTrust Secrets Manager image and pushes to Docker Hub.
# Tags follow the OpenClaw base version - e.g., 2026.3.13-1 + latest.
#
# Usage (run from repo root or scripts/ directory):
#   ./scripts/build-and-push.sh                                  # from repo root
#   ./build-and-push.sh                                          # from scripts/
#   ./scripts/build-and-push.sh --openclaw-tag "2026.3.13-1"     # pin to a specific version

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults & arg parsing
# ---------------------------------------------------------------------------

DOCKERHUB_USER="${DOCKERHUB_USER:-}"
OPENCLAW_TAG="latest"
IMAGE_NAME="thales-csm-openclaw"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)         DOCKERHUB_USER="$2"; shift 2;;
    --openclaw-tag) OPENCLAW_TAG="$2"; shift 2;;
    --name)         IMAGE_NAME="$2"; shift 2;;
    *) echo "Unknown option: $1"; exit 1;;
  esac
done

if [[ -z "$DOCKERHUB_USER" ]]; then
  read -rp "Docker Hub username: " DOCKERHUB_USER
  if [[ -z "$DOCKERHUB_USER" ]]; then
    echo "Docker Hub username is required. Pass --user or set DOCKERHUB_USER env var." >&2
    exit 1
  fi
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

FULL_IMAGE="${DOCKERHUB_USER}/${IMAGE_NAME}"
BASE_IMAGE="ghcr.io/openclaw/openclaw:${OPENCLAW_TAG}"

# Colors
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

echo -e "${CYAN}=== Building OpenClaw + CipherTrust Secrets Manager ===${NC}"
echo "  Base image:  ${BASE_IMAGE}"
echo ""

# ---------------------------------------------------------------------------
# Pull base
# ---------------------------------------------------------------------------

echo -e "${CYAN}[1/5] Pulling base image...${NC}"
docker pull "${BASE_IMAGE}"

# ---------------------------------------------------------------------------
# Detect OpenClaw version
# ---------------------------------------------------------------------------

echo -e "${CYAN}[2/5] Detecting OpenClaw version...${NC}"
# Go template must use real double quotes around the label key (inside outer single quotes).
# Do not use \" — that passes a backslash to docker and breaks template parsing.
VERSION_LABEL=$(docker inspect --format '{{ index .Config.Labels "org.opencontainers.image.version" }}' "${BASE_IMAGE}" 2>/dev/null || true)

if [[ -z "$VERSION_LABEL" || "$VERSION_LABEL" == "<no value>" ]]; then
  VERSION_LABEL=$(docker inspect --format '{{ index .Config.Labels "version" }}' "${BASE_IMAGE}" 2>/dev/null || true)
fi

if [[ -z "$VERSION_LABEL" || "$VERSION_LABEL" == "<no value>" ]] && [[ "$OPENCLAW_TAG" != "latest" ]]; then
  VERSION_LABEL="$OPENCLAW_TAG"
fi

if [[ -z "$VERSION_LABEL" || "$VERSION_LABEL" == "<no value>" ]]; then
  VERSION_LABEL=$(docker inspect --format '{{ .Id }}' "${BASE_IMAGE}" | cut -c8-19)
  echo -e "  ${YELLOW}Could not detect version label, using image hash: ${VERSION_LABEL}${NC}"
fi

echo -e "  ${GREEN}OpenClaw version: ${VERSION_LABEL}${NC}"

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

echo -e "${CYAN}[3/5] Building image...${NC}"
docker build \
  --build-arg "OPENCLAW_TAG=${OPENCLAW_TAG}" \
  --label "openclaw.base.version=${VERSION_LABEL}" \
  --label "openclaw.base.tag=${OPENCLAW_TAG}" \
  -f Dockerfile.akeyless \
  -t "${FULL_IMAGE}:${VERSION_LABEL}" \
  -t "${FULL_IMAGE}:latest" \
  .

echo -e "  ${GREEN}Tagged: ${FULL_IMAGE}:${VERSION_LABEL}${NC}"
echo -e "  ${GREEN}Tagged: ${FULL_IMAGE}:latest${NC}"

# ---------------------------------------------------------------------------
# Login check
# ---------------------------------------------------------------------------

echo -e "${CYAN}[4/5] Checking Docker Hub login...${NC}"
if ! docker info 2>&1 | grep -q "Username"; then
  echo -e "  ${YELLOW}Not logged in. Running: docker login${NC}"
  docker login
fi

# ---------------------------------------------------------------------------
# Push both tags
# ---------------------------------------------------------------------------

echo -e "${CYAN}[5/5] Pushing to Docker Hub...${NC}"
docker push "${FULL_IMAGE}:${VERSION_LABEL}"
docker push "${FULL_IMAGE}:latest"

echo ""
echo -e "${GREEN}=== Done ===${NC}"
echo "  Image:   ${FULL_IMAGE}:${VERSION_LABEL}"
echo "  Latest:  ${FULL_IMAGE}:latest"
echo "  Pull:    docker pull ${FULL_IMAGE}:${VERSION_LABEL}"
echo "           docker pull ${FULL_IMAGE}:latest"
