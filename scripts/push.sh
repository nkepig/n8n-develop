#!/usr/bin/env bash
# Push a previously built customer image to the configured registry.
#
# The client subdir is inferred from the current git branch (same as
# build.sh): branch `<user>/<client>-<date>` -> subdir `<client>-<date>`.
#
# Usage:
#   ./scripts/push.sh [image-tag]
#   ./scripts/push.sh 1.0
#   ./scripts/push.sh 1.0 --client client_a-20260706   # override client
#
# Env overrides:
#   REGISTRY   Docker registry (required; e.g. registry.example.com/n8n)
#   IMAGE_NAME base image name (default: n8n)
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
IMAGE_NAME="${IMAGE_NAME:-n8n}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -z "$REGISTRY" ]; then
  echo "Error: REGISTRY env var is required to push." >&2
  echo "Example: REGISTRY=registry.example.com/n8n $0 $TAG" >&2
  exit 64
fi

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

IMAGE_SUFFIX="$(echo "$CLIENT_DIR" | tr '_' '-' | tr '[:upper:]' '[:lower:]')"
IMAGE_REF="${REGISTRY%/}/${IMAGE_NAME}-${IMAGE_SUFFIX}:${TAG}"

echo "Pushing $IMAGE_REF"
docker push "$IMAGE_REF"
echo "Pushed: $IMAGE_REF"