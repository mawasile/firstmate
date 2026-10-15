#!/usr/bin/env bash
# Install this Firstmate home's scoped GitHub Copilot hooks.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
COPILOT_HOME="${COPILOT_HOME:-$HOME/.copilot}"
HOOK_DIR="$COPILOT_HOME/hooks"
scope=$(printf '%s' "$FM_HOME" | cksum | awk '{print $1}')
HOOK_FILE="${FM_COPILOT_HOOK_FILE:-$HOOK_DIR/firstmate-$scope.json}"
mkdir -p "$(dirname "$HOOK_FILE")"

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

root_q=$(shell_quote "$FM_ROOT")
home_q=$(shell_quote "$FM_HOME")
script_q=$(shell_quote "$SCRIPT_DIR/fm-copilot-hook.sh")
prefix="FM_ROOT_OVERRIDE=$root_q FM_HOME=$home_q $script_q"
tmp=$(mktemp "$(dirname "$HOOK_FILE")/.firstmate-hooks.XXXXXX")
trap 'rm -f "$tmp"' EXIT
jq -n \
  --arg session_start "$prefix session-start" \
  --arg session_end "$prefix session-end" \
  --arg pre_tool "$prefix pre-tool" \
  --arg agent_stop "$prefix agent-stop" \
  '{
    version: 1,
    hooks: {
      sessionStart: [{type:"command",bash:$session_start,timeoutSec:180}],
      sessionEnd: [{type:"command",bash:$session_end,timeoutSec:10}],
      preToolUse: [{type:"command",bash:$pre_tool,timeoutSec:15}],
      agentStop: [{type:"command",bash:$agent_stop,timeoutSec:15}]
    }
  }' >"$tmp"
chmod 600 "$tmp"
mv -f "$tmp" "$HOOK_FILE"
trap - EXIT
printf 'installed Copilot hooks: %s\n' "$HOOK_FILE"
