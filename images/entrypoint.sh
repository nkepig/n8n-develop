#!/bin/sh
# n8n customer image entrypoint.
#
# On first start (when N8N_INSTANCE_OWNER_MANAGED_BY_ENV=true and a marker file
# is absent), launches n8n briefly in the background so the instance owner is
# auto-created from env vars, runs `n8n import:workflow` against the built-in
# workflows directory, then restarts n8n in the foreground.
#
# Subsequent starts skip the import step (marker file present), so it is
# idempotent and safe across container rebuilds as long as the data volume
# persists.
set -e

WORKFLOWS_DIR="${N8N_BUILTIN_WORKFLOWS_DIR:-/workflows}"
DATA_DIR="${N8N_USER_FOLDER:-/home/node/.n8n}"
MARKER="$DATA_DIR/.builtin-workflows-imported"
HEALTH_URL="${N8N_PROTOCOL:-http}://${N8N_HOST:-0.0.0.0}:${N8N_PORT:-5678}/healthz"
# n8n listens on 0.0.0.0 inside the container regardless of N8N_HOST.
HEALTH_LOCAL="http://127.0.0.1:${N8N_PORT:-5678}/healthz"
STARTUP_TIMEOUT="${N8N_BUILTIN_IMPORT_TIMEOUT:-180}"

log() { printf '[entrypoint] %s\n' "$*"; }

wait_for_n8n() {
  pid=$1
  log "Waiting for n8n to be ready (up to ${STARTUP_TIMEOUT}s)..."
  i=0
  while [ "$i" -lt "$STARTUP_TIMEOUT" ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      log "n8n background process exited unexpectedly during startup." >&2
      return 1
    fi
    if node -e "const http=require('http');const r=http.get('$HEALTH_LOCAL',x=>process.exit(x.statusCode===200?0:1)).on('error',()=>process.exit(1));r.setTimeout(1500,()=>r.destroy());" 2>/dev/null; then
      log "n8n is ready (after ${i}s)."
      return 0
    fi
    i=$((i+1))
    sleep 1
  done
  log "Timed out waiting for n8n healthz at $HEALTH_LOCAL." >&2
  return 1
}

import_workflows() {
  if [ ! -d "$WORKFLOWS_DIR" ]; then
    log "No built-in workflows directory at $WORKFLOWS_DIR; skipping import."
    return 0
  fi
  if [ -f "$MARKER" ]; then
    log "Built-in workflows already imported (marker present at $MARKER)."
    return 0
  fi
  if [ -z "$(ls -A "$WORKFLOWS_DIR" 2>/dev/null)" ]; then
    log "Built-in workflows directory is empty; nothing to import."
    return 0
  fi
  if [ "$N8N_INSTANCE_OWNER_MANAGED_BY_ENV" != "true" ]; then
    log "N8N_INSTANCE_OWNER_MANAGED_BY_ENV is not 'true'; cannot import without an owner." >&2
    log "Set owner env vars (see .env.example) or complete the UI setup, then restart." >&2
    return 0
  fi

  log "Built-in workflows detected at $WORKFLOWS_DIR; starting n8n in background to bootstrap owner..."
  n8n start &
  n8n_pid=$!

  if ! wait_for_n8n "$n8n_pid"; then
    kill "$n8n_pid" 2>/dev/null || true
    wait "$n8n_pid" 2>/dev/null || true
    log "Import aborted; will retry on next start." >&2
    return 1
  fi

  # Extra buffer: OwnerInstanceSettingsLoader runs early in startup, but give
  # it a couple more seconds to commit the owner row before we hit import.
  sleep 5

  log "Importing workflows from $WORKFLOWS_DIR ..."
  if n8n import:workflow --input="$WORKFLOWS_DIR" --separate; then
    mkdir -p "$DATA_DIR"
    touch "$MARKER"
    log "Import complete. Marker written to $MARKER."
  else
    log "n8n import:workflow failed; will retry on next start." >&2
  fi

  log "Stopping background n8n (pid $n8n_pid)..."
  kill "$n8n_pid" 2>/dev/null || true
  wait "$n8n_pid" 2>/dev/null || true
}

import_workflows

log "Starting n8n in foreground..."
exec n8n start