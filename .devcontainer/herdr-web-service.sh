#!/usr/bin/env bash
# herdr-web-service.sh - keep herdr-web running whenever Herdr is running.
#
# Usage:
#   herdr-web-service.sh start   detach one background service and return
#   herdr-web-service.sh run     run the service loop in the foreground
#
# devcontainer.json's postStartCommand calls `start` on every container start.
# The loop waits until `herdr status` reports a running server, then runs
# `herdr-web --host 0.0.0.0 --port 8787 --allow-origin http://localhost` and
# restarts it after it exits, so herdr-web follows Herdr however late Herdr
# starts. Binding 0.0.0.0 inside the container is what lets Docker's published
# port reach the bridge; Docker publishes 8787 on every host address, so other
# devices on the host's network can reach it, and the allowed origin lets the
# herdr-web Android app connect. herdr-web has no login of its own. A lock
# keeps one service per container, and a bridge already running (started by
# hand) is left alone.
set -u

STATE_DIR=${XDG_STATE_HOME:-$HOME/.local/state}
LOG=$STATE_DIR/herdr-web.log
LOCK=$STATE_DIR/herdr-web-service.lock
POLL_SECS=${HERDR_WEB_SERVICE_POLL_SECS:-5}
export PATH="$HOME/.local/bin:$PATH"

log() {
  printf '%s herdr-web-service: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >>"$LOG"
}

herdr_running() {
  [ "$(timeout 5 herdr status --json 2>/dev/null \
    | jq -r '.server.running // false' 2>/dev/null)" = true ]
}

bridge_running() {
  pgrep -u "$(id -u)" -f '^[^ ]*/herdr-web-bridge( |$)' >/dev/null 2>&1
}

run() {
  mkdir -p "$STATE_DIR"
  exec 9>"$LOCK"
  flock -n 9 || exit 0
  command -v herdr-web >/dev/null 2>&1 || { log "herdr-web is not installed; exiting"; exit 1; }
  log "started (pid $$)"
  while :; do
    if herdr_running && ! bridge_running; then
      log "Herdr is running; starting herdr-web on 0.0.0.0:8787"
      herdr-web --host 0.0.0.0 --port 8787 --allow-origin http://localhost \
        >>"$LOG" 2>&1 </dev/null 9>&-
      log "herdr-web exited with status $?"
    fi
    sleep "$POLL_SECS"
  done
}

case "${1:-}" in
  run) run ;;
  start)
    mkdir -p "$STATE_DIR"
    setsid nohup bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")" run \
      >>"$LOG" 2>&1 </dev/null &
    ;;
  *) echo "usage: $0 start|run" >&2; exit 2 ;;
esac
