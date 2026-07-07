#!/usr/bin/env bash
# Export all workflows from the running n8n-dev container into
# workflows/<client>/*.json, one file per workflow, named by the workflow's
# title (with a -2/-3/... suffix on title collisions).
#
# The target subdir is inferred from the current git branch: branch
# `<user>/<client>` maps to subdir `<client>`. So you must be on a customer
# branch (not master) before running this.
#
# Usage:
#   ./scripts/sync-from-running.sh
#
# No arguments. Container is always n8n-dev. Client dir is always inferred
# from the current git branch.
set -euo pipefail

CONTAINER="n8n-dev"

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

# 5. Prepare destination and copy files out, renaming each to <title>.json.
mkdir -p "$DEST"
PY=/opt/homebrew/bin/python3.13
if [ ! -x "$PY" ]; then PY=python3; fi
if ! command -v "$PY" >/dev/null 2>&1; then
  echo "Error: python3 is required for title-based renaming." >&2
  exit 70
fi

# Collect (original_filename, title) pairs first so collision counting is
# stable regardless of docker exec ls order.
PAIRS=""
while IFS= read -r f; do
  title="$("$PY" - <<PYEOF "$CONTAINER" "$f"
import json, subprocess, sys
container, path = sys.argv[1], sys.argv[2]
raw = subprocess.check_output(["docker", "exec", container, "cat", path], text=True)
data = json.loads(raw)
print(data.get("name") or "workflow")
PYEOF
)"
  # Use a NUL-free delimiter unlikely to appear in titles.
  PAIRS="${PAIRS}${title}"$'\t'"$(basename "$f")"$'\n'
done < <(docker exec "$CONTAINER" sh -c "ls -1 '$TMP_DIR'/*.json 2>/dev/null")

# Copy each file out, choosing a unique filename per title: first occurrence
# uses <title>.json, subsequent collisions become <title>-2.json, -3, ...
USED_NAMES=""
copied=0
while IFS=$'\t' read -r title orig; do
  [ -z "$title" ] && continue
  safe="$("$PY" - <<PYEOF "$title"
import re, sys
name = sys.argv[1]
safe = re.sub(r'[\\/:*?"<>|\s]+', '_', name).strip(' .')
print(safe[:60] or "workflow")
PYEOF
)"
  out_name="${safe}.json"
  cnt=2
  while printf '%s\n' "$USED_NAMES" | grep -qxF "$out_name"; do
    out_name="${safe}-${cnt}.json"
    cnt=$((cnt+1))
  done
  USED_NAMES="${USED_NAMES}${out_name}"$'\n'
  docker cp "$CONTAINER:$TMP_DIR/$orig" "$DEST/$out_name"
  copied=$((copied+1))
  echo "  $out_name"
done <<EOF
$PAIRS
EOF

echo "Copied $copied file(s) to workflows/$CLIENT_DIR/."

# 7. List result.
echo
echo "workflows/$CLIENT_DIR/ now contains:"
( cd "$DEST" && ls -1 *.json 2>/dev/null | sed 's/^/  /' ) || echo "  (no json files)"

echo
echo "Next: git add workflows/$CLIENT_DIR/ && git commit -m 'sync workflows from running n8n'"
