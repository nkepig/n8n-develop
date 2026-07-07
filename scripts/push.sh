#!/usr/bin/env bash
# Push the most recently built customer image to Docker Hub.
#
# Reads the image ref from .last-built-image (written by build.sh), then
# auto-detects your Docker Hub username from the local docker config /
# keychain, retags the local image to <username>/<image>:<tag>, and pushes.
#
# Usage:
#   ./scripts/push.sh                       # push the last built image
#   ./scripts/push.sh 1.0                   # override tag only
#   REGISTRY=dazey ./scripts/push.sh 1.0    # override username (or use private registry)
#
# First-time setup: docker login
set -euo pipefail

TAG="${1:-}"
REGISTRY_OVERRIDE="${REGISTRY:-}"
IMAGE_NAME="${IMAGE_NAME:-n8n}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Detect Docker Hub username from local docker login state.
#   1. ~/.docker/config.json with `auths[].auth` (base64 of user:pass)
#   2. macOS keychain (credsStore=osxkeychain) via `security` lookup
#   3. REGISTRY env var override
detect_registry() {
  if [ -n "$REGISTRY_OVERRIDE" ]; then
    echo "$REGISTRY_OVERRIDE"
    return 0
  fi
  local cfg="$HOME/.docker/config.json"
  if [ -f "$cfg" ]; then
    local user
    user="$(python3 - "$cfg" <<'PYEOF' 2>/dev/null
import json, base64, sys
with open(sys.argv[1]) as f: d = json.load(f)
auths = d.get('auths', {})
hub = auths.get('https://index.docker.io/v1/', {})
if 'auth' in hub:
    print(base64.b64decode(hub['auth']).decode().split(':')[0])
PYEOF
)"
    if [ -n "$user" ]; then
      echo "$user"
      return 0
    fi
  fi
  if [ "$(uname)" = "Darwin" ] && command -v security >/dev/null 2>&1; then
    local user
    user="$(security find-internet-password -s 'index.docker.io' 2>/dev/null \
            | grep '"acct"' \
            | sed -E 's/.*"acct"<blob>="([^"]*)".*/\1/' \
            | head -1)"
    if [ -n "$user" ]; then
      echo "$user"
      return 0
    fi
  fi
  return 1
}

LAST_BUILT="$REPO_ROOT/.last-built-image"
LOCAL_REF=""
if [ -z "$TAG" ] && [ -z "$REGISTRY_OVERRIDE" ] && [ -f "$LAST_BUILT" ]; then
  LOCAL_REF="$(cat "$LAST_BUILT")"
  echo "Using last built image: $LOCAL_REF"
else
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
      exit 64
      ;;
  esac
  IMAGE_SUFFIX="$(echo "$CLIENT_DIR" | tr '_' '-' | tr '[:upper:]' '[:lower:]')"
  LOCAL_REF="${IMAGE_NAME}-${IMAGE_SUFFIX}:${TAG:-latest}"
fi

REGISTRY="$(detect_registry)" || {
  echo "Error: could not detect Docker Hub username." >&2
  echo "Run 'docker login' first, or set REGISTRY=<your-username>." >&2
  exit 64
}

# Reconstruct the remote image ref from the local ref + detected registry.
LOCAL_BASE="${LOCAL_REF%%:*}"
LOCAL_TAG="${LOCAL_REF##*:}"
REMOTE_REF="${REGISTRY%/}/${LOCAL_BASE}:${LOCAL_TAG}"

if [ "$LOCAL_REF" = "$REMOTE_REF" ]; then
  echo "Pushing $LOCAL_REF"
  docker push "$LOCAL_REF"
else
  echo "Retagging $LOCAL_REF -> $REMOTE_REF"
  docker tag "$LOCAL_REF" "$REMOTE_REF"
  echo "Pushing $REMOTE_REF"
  docker push "$REMOTE_REF"
fi
echo "Pushed: $REMOTE_REF"