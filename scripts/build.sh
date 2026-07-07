#!/usr/bin/env bash
# Build a customer-specific n8n image (local only; push.sh handles registry).
#
# The client subdir is inferred from the current git branch: branch
# `<user>/<client>` maps to subdir `<client>` under workflows/.
# So you must be on a customer branch (not master) before running this.
#
# Uses docker buildx with --platform linux/amd64 because customer servers
# are typically amd64 even when the dev machine is arm64 (Apple Silicon).
# --load makes the built image available to the local docker daemon.
#
# Usage:
#   ./scripts/build.sh [image-tag]
#   ./scripts/build.sh 1.0
#
# Env overrides:
#   BASE_N8N_IMAGE    base n8n image to FROM (default: ghcr.io/deluxebear/n8n:chs)
#   IMAGE_NAME        base image name (default: n8n)
set -euo pipefail

TAG="${1:-latest}"
BASE_N8N_IMAGE="${BASE_N8N_IMAGE:-ghcr.io/deluxebear/n8n:chs}"
IMAGE_NAME="${IMAGE_NAME:-n8n}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
if [ -z "$BRANCH" ] || [ "$BRANCH" = "HEAD" ]; then
  echo "Error: not on a git branch." >&2
  echo "Create a customer branch first, e.g.:" >&2
  echo "  git checkout -b <user>/<client>" >&2
  exit 64
fi
CLIENT_DIR="${BRANCH##*/}"
case "$CLIENT_DIR" in
  master|main|develop|dev)
    echo "Error: current branch '$BRANCH' is not a customer branch." >&2
    echo "Customer branches look like <user>/<client>." >&2
    echo "Create one first:  git checkout -b <user>/<client>" >&2
    exit 64
    ;;
esac

if [ ! -d "$REPO_ROOT/workflows/$CLIENT_DIR" ]; then
  echo "Error: workflows/$CLIENT_DIR does not exist." >&2
  echo "Run ./scripts/sync-from-running.sh first to populate it." >&2
  exit 66
fi

IMAGE_SUFFIX="$(echo "$CLIENT_DIR" | tr '_' '-' | tr '[:upper:]' '[:lower:]')"
IMAGE_REF="${IMAGE_NAME}-${IMAGE_SUFFIX}:${TAG}"

echo "Building $IMAGE_REF"
echo "  BASE_N8N_IMAGE : $BASE_N8N_IMAGE"
echo "  CLIENT_DIR     : $CLIENT_DIR"
echo "  Platform       : linux/amd64"
echo "  Context        : $REPO_ROOT"

docker buildx build \
  --platform linux/amd64 \
  --build-arg TARGETOS=linux \
  --build-arg TARGETARCH=amd64 \
  --build-arg N8N_IMAGE="$BASE_N8N_IMAGE" \
  --build-arg CLIENT_DIR="$CLIENT_DIR" \
  -t "$IMAGE_REF" \
  --load \
  -f "$REPO_ROOT/images/Dockerfile" \
  "$REPO_ROOT"

echo "Built: $IMAGE_REF"
echo "$IMAGE_REF" > "$REPO_ROOT/.last-built-image"
echo "Next: docker login && ./scripts/push.sh"