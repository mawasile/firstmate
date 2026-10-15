#!/usr/bin/env bash
# GitHub Copilot CLI and SDK hook adapter.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
PAYLOAD=$(cat 2>/dev/null || true)
command -v jq >/dev/null 2>&1 || exit 0

session_id=$(printf '%s' "$PAYLOAD" | jq -r '.sessionId // .session_id // empty' 2>/dev/null) || exit 0
case "$session_id" in ''|*[!A-Za-z0-9._-]*) exit 0 ;; esac
hook_cwd=$(printf '%s' "$PAYLOAD" | jq -r '.cwd // empty' 2>/dev/null) || exit 0
root_real=$(cd "$FM_ROOT" 2>/dev/null && pwd -P) || exit 0
cwd_root=$(git -C "$hook_cwd" rev-parse --show-toplevel 2>/dev/null || true)
[ -z "$cwd_root" ] || cwd_root=$(cd "$cwd_root" 2>/dev/null && pwd -P || true)
home_real=$(cd "$FM_HOME" 2>/dev/null && pwd -P || true)
if [ "$cwd_root" != "$root_real" ]; then
  if [ -z "$home_real" ] || [ "$cwd_root" != "$home_real" ] || [ ! -f "$FM_HOME/.fm-secondmate-home" ]; then
    printf '{}\n'
    exit 0
  fi
fi
export COPILOT_CLI=1
export COPILOT_AGENT_SESSION_ID=$session_id

# shellcheck source=bin/fm-copilot-lib.sh
. "$SCRIPT_DIR/fm-copilot-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

runtime_pid=$(_fm_session_lock_copilot_runtime_pid "$(fm_harness_ancestry_pids 2>/dev/null || true)" 2>/dev/null || true)
case "$runtime_pid" in ''|*[!0-9]*) exit 0 ;; esac
copilot_home=${COPILOT_HOME:-${HOME:-}/.copilot}
hold_path="$copilot_home/session-state/$session_id/inuse.$runtime_pid.hold"
record_dir="$STATE/copilot-sessions"
record="$record_dir/$session_id.owner"

json_reason() {
  local text=$1
  printf '%s\n' "$text" | tail -n 1 | jq -Rr 'fromjson? | .systemMessage // empty' 2>/dev/null
}

run_pretool_check() {  # <script> <args...>
  local script=$1 output status=0 reason
  shift
  output=$("$SCRIPT_DIR/$script" --claude "$@" 2>&1) || status=$?
  [ "$status" -eq 2 ] || return 1
  reason=$(json_reason "$output")
  [ -n "$reason" ] || reason=$(printf '%s\n' "$output" | tail -n 1)
  jq -n --arg reason "${reason:-Firstmate denied this tool call.}" \
    '{permissionDecision:"deny",permissionDecisionReason:$reason}'
  return 0
}

case "${1:-}" in
  session-start)
    mkdir -p "$record_dir" 2>/dev/null || {
      jq -n '{additionalContext:"Firstmate could not create its Copilot session record. Operate read-only and report the state-directory error."}'
      exit 0
    }
    guardian=$(node "$SCRIPT_DIR/fm-copilot-session.mjs" start "$session_id" "$runtime_pid" "$hold_path" "$record" 2>/dev/null || true)
    case "$guardian" in
      ''|*[!0-9]*)
        jq -n '{additionalContext:"Firstmate could not establish a session-specific Copilot owner. Operate read-only and run `bin/fm-session-start.sh` only after the guardian error is resolved."}'
        exit 0
        ;;
    esac
    export FM_COPILOT_SESSION_PID=$guardian
    source=$(printf '%s' "$PAYLOAD" | jq -r '.source // "startup"' 2>/dev/null || printf startup)
    output=$("$SCRIPT_DIR/fm-sessionstart-run.sh" --source "$source" 2>&1)
    jq -n --arg context "$output" '{additionalContext:$context}'
    ;;
  session-end)
    node "$SCRIPT_DIR/fm-copilot-session.mjs" stop "$session_id" "$record" >/dev/null 2>&1 || true
    ;;
  pre-tool)
    tool=$(printf '%s' "$PAYLOAD" | jq -r '.toolName // .tool_name // empty' 2>/dev/null) || exit 0
    command=$(printf '%s' "$PAYLOAD" | jq -r '.toolArgs.command // .tool_input.command // empty' 2>/dev/null) || command=
    case "$tool" in
      bash|Bash)
        run_pretool_check fm-arm-pretool-check.sh --command "$command" && exit 0
        run_pretool_check fm-cd-pretool-check.sh --command "$command" && exit 0
        ;;
    esac
    run_pretool_check fm-subagent-pretool-check.sh --tool "$tool" && exit 0
    printf '{}\n'
    ;;
  agent-stop)
    output=$(printf '%s' "$PAYLOAD" | "$SCRIPT_DIR/fm-turnend-guard.sh" --copilot 2>&1)
    status=$?
    if [ "$status" -eq 2 ]; then
      body="TURN WOULD END BLIND - supervision is off. Run the foreground checkpoint from the Copilot session-start instructions before ending the turn.

$output"
      encoded=$("$SCRIPT_DIR/fm-operational-input.sh" encode turn-end-guard "$body" 2>/dev/null || printf '%s' "$body")
      jq -n --arg reason "$encoded" '{decision:"block",reason:$reason}'
    else
      printf '{}\n'
    fi
    ;;
  *)
    echo "usage: fm-copilot-hook.sh session-start|session-end|pre-tool|agent-stop" >&2
    exit 2
    ;;
esac
