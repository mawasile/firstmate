#!/usr/bin/env bash
# Token-free live proof for the shared VS Code Copilot SDK runtime.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_COPILOT_SDK_PRIMARY_LIVE_E2E node

if [ "${COPILOT_CLI:-}" != 1 ] || [ -z "${COPILOT_AGENT_SESSION_ID:-}" ] \
  || [ "$("$ROOT/bin/fm-harness.sh")" != copilot ]; then
  if [ "${FM_COPILOT_SDK_PRIMARY_LIVE_E2E:-}" = 1 ] || [ "${FM_LIVE:-}" = 1 ]; then
    fail "Copilot SDK markers and runtime ancestry are not present"
  fi
  printf 'skip: live: current process is not a Copilot SDK session\n'
  exit 0
fi

TMP_ROOT=$(fm_test_tmproot fm-copilot-sdk-primary-live)
STATE="$TMP_ROOT/state"
RECORD="$TMP_ROOT/session.owner"
mkdir -p "$STATE"
guardian=

cleanup() {
  if [ -n "$guardian" ]; then
    node "$ROOT/bin/fm-copilot-session.mjs" stop \
      "$COPILOT_AGENT_SESSION_ID" "$RECORD" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

runtime=$(
  bash -c '
    . "$1/bin/fm-session-lock-lib.sh"
    _fm_session_lock_copilot_runtime_pid "$(fm_harness_ancestry_pids)"
  ' _ "$ROOT"
) || fail "could not identify the live Copilot SDK runtime"
hold="$COPILOT_HOME/session-state/$COPILOT_AGENT_SESSION_ID/inuse.$runtime.hold"
guardian=$(node "$ROOT/bin/fm-copilot-session.mjs" start \
  "$COPILOT_AGENT_SESSION_ID" "$runtime" "$hold" "$RECORD") \
  || fail "could not start the Copilot logical-session guardian"

FM_STATE_OVERRIDE="$STATE" FM_COPILOT_SESSION_PID="$guardian" \
  "$ROOT/bin/fm-lock.sh" >/dev/null \
  || fail "the Copilot SDK logical session could not acquire its isolated test lock"
FM_STATE_OVERRIDE="$STATE" bash -c '
  . "$1/bin/fm-session-lock-lib.sh"
  fm_session_lock_owned_by_self "$FM_STATE_OVERRIDE"
' _ "$ROOT" \
  || fail "a normal Copilot SDK tool subprocess did not retain logical-session ownership"
[ "$(ps -p "$guardian" -o comm= | tr -d ' ')" = fm-copilot-ses ] \
  || fail "the recorded Copilot guardian does not have the verified process identity"

pass "copilot SDK live: shared runtime retained session-specific lock ownership"
