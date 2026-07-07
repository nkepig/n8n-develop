#!/bin/sh
# n8n customer image entrypoint.
#
# On first start (marker file absent), launches n8n in the background and
# polls /rest/settings for userManagement.showSetupOnFirstLoad. The user
# completes the owner setup wizard in the browser (choosing their own email
# and password). Once setup is done, this script imports the built-in
# workflows from /workflows, writes a marker file, and restarts n8n in the
# foreground.
#
# Subsequent starts skip the import step (marker present), so it is
# idempotent and safe across container rebuilds as long as the data volume
# persists.
set -e

WORKFLOWS_DIR="${N8N_BUILTIN_WORKFLOWS_DIR:-/workflows}"
DATA_DIR="${N8N_USER_FOLDER:-/home/node/.n8n}"
MARKER="$DATA_DIR/.builtin-workflows-imported"
HEALTH_LOCAL="http://127.0.0.1:${N8N_PORT:-5678}/healthz"
SETTINGS_LOCAL="http://127.0.0.1:${N8N_PORT:-5678}/rest/settings"
STARTUP_TIMEOUT="${N8N_BUILTIN_IMPORT_TIMEOUT:-180}"
SETUP_POLL_INTERVAL="${N8N_BUILTIN_SETUP_POLL_INTERVAL:-5}"

log() { printf '[entrypoint] %s\n' "$*"; }

# Returns 0 if n8n is reachable and healthy, 1 otherwise.
n8n_healthy() {
  node -e "const http=require('http');const r=http.get('$HEALTH_LOCAL',x=>process.exit(x.statusCode===200?0:1)).on('error',()=>process.exit(1));r.setTimeout(1500,()=>r.destroy());" 2>/dev/null
}

# Returns 0 if owner setup is still pending (showSetupOnFirstLoad=true),
# 1 if setup is complete, 2 on error.
setup_pending() {
  node -e "
const http=require('http');
const r=http.get('$SETTINGS_LOCAL',res=>{
  let b='';
  res.on('data',c=>b+=c);
  res.on('end',()=>{
    try{
      const j=JSON.parse(b);
      const s=(j.data&&j.data.userManagement&&j.data.userManagement.showSetupOnFirstLoad);
      process.exit(s?0:1);
    }catch(e){process.exit(2);}
  });
}).on('error',()=>process.exit(2));
r.setTimeout(3000,()=>r.destroy());
" 2>/dev/null
}

wait_for_n8n() {
  pid=$1
  log "Waiting for n8n to be ready (up to ${STARTUP_TIMEOUT}s)..."
  i=0
  while [ "$i" -lt "$STARTUP_TIMEOUT" ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      log "n8n background process exited unexpectedly during startup." >&2
      return 1
    fi
    if n8n_healthy; then
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

  log "Built-in workflows detected at $WORKFLOWS_DIR; starting n8n in background..."
  n8n start &
  n8n_pid=$!

  if ! wait_for_n8n "$n8n_pid"; then
    kill "$n8n_pid" 2>/dev/null || true
    wait "$n8n_pid" 2>/dev/null || true
    log "Import aborted; will retry on next start." >&2
    return 1
  fi

  log "--------------------------------------------------------------"
  log "请用浏览器打开 n8n,完成 owner 账号创建(邮箱+密码自行设置)。"
  log "完成后工作流将自动导入,无需手动操作。"
  log "--------------------------------------------------------------"

  # Poll until the user completes the UI setup wizard.
  # Disable set -e here because setup_pending returns non-zero both when
  # setup is complete (1) and on transient errors (2); either would abort
  # the whole script under set -e.
  while true; do
    if ! kill -0 "$n8n_pid" 2>/dev/null; then
      log "n8n background process exited during setup wait." >&2
      return 1
    fi
    rc=0
    setup_pending || rc=$?
    if [ "$rc" -eq 1 ]; then
      log "Owner setup complete."
      break
    elif [ "$rc" -eq 2 ]; then
      log "Could not read setup status from n8n; retrying in ${SETUP_POLL_INTERVAL}s..."
    fi
    sleep "$SETUP_POLL_INTERVAL"
  done

  # Small buffer: let n8n finish persisting the owner row before import.
  sleep 3

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
