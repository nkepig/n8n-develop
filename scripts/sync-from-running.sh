#!/usr/bin/env bash
# One-click export all workflows from a running n8n container into
# workflows/<client-date>/*.json.
#
# The target subdir is inferred from the current git branch: branch
# `<user>/<client>-<date>` maps to subdir `<client>-<date>`. So you must be on
# a customer branch (not master) before running this.
#
# Usage:
#   ./scripts/sync-from-running.sh [--container <name>] [--rename]
#   ./scripts/sync-from-running.sh --client client_a-20260706 --rename   # override
#
# Options:
#   --container <name>   n8n container name (default: n8n-dev)
#   --rename             use <safe-name>__<id>.json instead of <id>.json
#   --client <dir>       override the inferred client subdir
set -euo pipefail

CONTAINER="n8n-dev"
RENAME=0
CLIENT_DIR=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --container) CONTAINER="$2"; shift 2 ;;
    --rename)    RENAME=1; shift ;;
    --client)    CLIENT_DIR="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "Unexpected argument: $1" >&2; exit 64 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Infer client subdir from the current git branch when not explicitly given.
# Branch `<user>/<client>-<date>` -> subdir `<client>-<date>`.
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

DEST="$REPO_ROOT/workflows/$CLIENT_DIR"

# 1. Container running?
if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "Error: container '$CONTAINER' is not running." >&2
  echo "Start it first, e.g.:" >&2
  echo "  docker run -d --name $CONTAINER -p 5678:5678 -v n8n_dev_data:/home/node/.n8n ghcr.io/deluxebear/n8n:chs" >&2
  echo "or, if it already exists:" >&2
  echo "  docker start $CONTAINER" >&2
  exit 66
fi

# 2. Export inside the container to a temp dir. `n8n export:workflow` exits
#    non-zero with "No workflows found" when the DB is empty, which is not a
#    real failure for our purposes — handle it gracefully.
TMP_DIR="/tmp/n8n-export-$$"
echo "Exporting workflows from container '$CONTAINER' -> workflows/$CLIENT_DIR/ ..."
EXPORT_OUTPUT="$(docker exec "$CONTAINER" sh -c "mkdir -p '$TMP_DIR' && n8n export:workflow --backup --output='$TMP_DIR' 2>&1" || true)"

# 3. Always clean up the container-side temp dir on exit.
cleanup() {
  docker exec "$CONTAINER" rm -rf "$TMP_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# 4. Count exported files. If 0, surface the n8n error message (usually
#    "No workflows found with specified filters") and exit cleanly.
COUNT=$(docker exec "$CONTAINER" sh -c "ls -1 '$TMP_DIR'/*.json 2>/dev/null | wc -l" | tr -d ' \t\r\n')
if [ -z "$COUNT" ] || [ "$COUNT" -eq 0 ]; then
  echo "No workflows found in the container (DB may be empty). Nothing to sync."
  if [ -n "$EXPORT_OUTPUT" ]; then
    echo "n8n said: $EXPORT_OUTPUT" >&2
  fi
  exit 0
fi
echo "Exported $COUNT workflow(s)."

# 5. Prepare destination.
mkdir -p "$DEST"
NEW_FILES=()
while IFS= read -r f; do
  fname="$(basename "$f")"
  NEW_FILES+=("$fname")
  docker cp "$CONTAINER:$f" "$DEST/$fname"
done < <(docker exec "$CONTAINER" sh -c "ls -1 '$TMP_DIR'/*.json 2>/dev/null")

echo "Copied ${#NEW_FILES[@]} file(s) to workflows/$CLIENT_DIR/."

# 6. Optional rename: <workflowId>.json -> <safe-name>__<workflowId>.json
if [ "$RENAME" -eq 1 ]; then
  PY=/opt/homebrew/bin/python3.13
  if [ ! -x "$PY" ]; then PY=python3; fi
  if ! command -v "$PY" >/dev/null 2>&1; then
    echo "Warning: --rename requested but no python3 found; keeping id-only filenames." >&2
  else
    renamed=0
    for fname in "${NEW_FILES[@]}"; do
      path="$DEST/$fname"
      new_name="$("$PY" - <<PYEOF "$path"
import json, re, sys
with open(sys.argv[1], 'r', encoding='utf-8') as f:
    data = json.load(f)
name = data.get('name') or 'workflow'
wf_id = data.get('id') or fname[:-5]
safe = re.sub(r'[^A-Za-z0-9._-]+', '_', name).strip('_') or 'workflow'
safe = safe[:60]
print(f"{safe}__{wf_id}.json")
PYEOF
)"
      if [ -n "$new_name" ] && [ "$new_name" != "$fname" ]; then
        mv "$path" "$DEST/$new_name"
        renamed=$((renamed+1))
      fi
    done
    echo "Renamed $renamed file(s) to <name>__<id>.json."
  fi
fi

# 7. List result.
echo
echo "workflows/$CLIENT_DIR/ now contains:"
( cd "$DEST" && ls -1 *.json 2>/dev/null | sed 's/^/  /' ) || echo "  (no json files)"

echo
echo "Next: git add workflows/$CLIENT_DIR/ && git commit -m 'sync workflows from running n8n'"