#!/usr/bin/env bash
# Build a customer-specific n8n image.
#
# The client subdir is inferred from the current git branch: branch
# `<user>/<client>-<date>` maps to subdir `<client>-<date>` under workflows/.
# So you must be on a customer branch (not master) before running this.
#
# Usage:
#   ./scripts/build.sh [image-tag]
#   ./scripts/build.sh 1.0
#   ./scripts/build.sh 1.0 --client client_a-20260706   # override client
#
# Env overrides:
#   REGISTRY          Docker registry (default: empty -> local image only)
#   BASE_N8N_IMAGE    base n8n image to FROM (default: ghcr.io/deluxebear/n8n:chs)
#   IMAGE_NAME        base image name (default: n8n)
set -euo pipefail

TAG=""
CLIENT_DIR=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --client) CLIENT_DIR="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      if [ -z "$TAG" ]; then
        TAG="$1"; shift
      else
        echo "Unexpected argument: $1" >&2; exit 64
      fi ;;
  esac
done

TAG="${TAG:-latest}"
REGISTRY="${REGISTRY:-}"
BASE_N8N_IMAGE="${BASE_N8N_IMAGE:-ghcr.io/deluxebear/n8n:chs}"
IMAGE_NAME="${IMAGE_NAME:-n8n}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Infer client subdir from the current git branch when not explicitly given.
if [ -z "$CLIENT_DIR" ]; then
  BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [ -z "$BRANCH" ] || [ "$BRANCH" = "HEAD" ]; then
    echo "Error: not on a git branch, and --client was not given." >&2
    echo "Create a customer branch first, e.g.:" >&2
    echo "  git checkout -b <user>/<client>-<YYYYMMDD>" >&2
    exit 64
  fi
  CLIENT_DIR="${BRANCH##*/}"
  case "$CLIENT_DIR" in
    master|main|develop|dev)
      echo "Error: current branch '$BRANCH' is not a customer branch." >&2
      echo "Customer branches look like <user>/<client>-<YYYYMMDD>." >&2
      echo "Create one first:  git checkout -b <user>/<client>-<YYYYMMDD>" >&2
      exit 64
      ;;
  esac
fi

if [ ! -d "$REPO_ROOT/workflows/$CLIENT_DIR" ]; then
  echo "Error: workflows/$CLIENT_DIR does not exist." >&2
  echo "Run ./scripts/sync-from-running.sh first to populate it." >&2
  exit 66
fi

# Docker image name disallows uppercase; underscores are tolerated by some
# registries but not all. Convert to dashes for maximum compatibility.
IMAGE_SUFFIX="$(echo "$CLIENT_DIR" | tr '_' '-' | tr '[:upper:]' '[:lower:]')"
BASE="$IMAGE_NAME-$IMAGE_SUFFIX"
if [ -n "$REGISTRY" ]; then
  IMAGE_REF="${REGISTRY%/}/${BASE}:${TAG}"
else
  IMAGE_REF="${BASE}:${TAG}"
fi

echo "Building $IMAGE_REF"
echo "  BASE_N8N_IMAGE : $BASE_N8N_IMAGE"
echo "  CLIENT_DIR     : $CLIENT_DIR"
echo "  Context        : $REPO_ROOT"

docker build \
  --build-arg N8N_IMAGE="$BASE_N8N_IMAGE" \
  --build-arg CLIENT_DIR="$CLIENT_DIR" \
  -t "$IMAGE_REF" \
  -f "$REPO_ROOT/images/Dockerfile" \
  "$REPO_ROOT"

echo "Built: $IMAGE_REF"
if [ -z "$REGISTRY" ]; then
  echo "REGISTRY not set; image is local only. Run scripts/push.sh to push." >&2
fi