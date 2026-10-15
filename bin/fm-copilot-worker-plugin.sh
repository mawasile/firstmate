#!/usr/bin/env bash
# Write a private GitHub Copilot CLI worker plugin carrying lifecycle hooks.
# Usage: fm-copilot-worker-plugin.sh <state-dir> <task-id> <busy-gen>
# Output: <state-dir>/<task-id>.copilot-plugin/plugin.json (directory mode 700,
# manifest mode 600, atomically replaced). fm-spawn mounts the directory for one
# worker with --plugin-dir; no user, project, or global Copilot config is
# edited. fm-control-lib.sh retires the manifest on relaunch and fm-teardown.sh
# removes the directory.
# The manifest is a legacy Copilot plugin with its hooks inline and no version
# wrapper; Copilot CLI 1.0.97 loads that shape but silently ignores the same
# hooks nested under a {"version":1,"hooks":{...}} wrapper.
# userPromptSubmitted opens a turn - including the -i launch prompt, the
# steering messages typed into the TUI, and the synthetic prompt a finished
# background shell submits; agentStop and sessionEnd close it. Copilot 1.0.97
# emits no agentStop when a turn is cancelled with Escape, so fm-control
# invalidates the state to unknown after delivering that interrupt, never
# fabricating idle. Turn-end touches follow a successful generation-bound
# apply; events rejected as stale emit no notification.
set -eu
case "${1:-}" in
  -h|--help)
    sed -n '2,/^set -eu/{ /^#/s/^# \{0,1\}//p; }' "$0"
    exit 0
    ;;
esac
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE=${1:?state directory required}
ID=${2:?task id required}
GEN=${3:?busy generation required}
case "$ID" in ''|*[!A-Za-z0-9._-]*) echo 'error: invalid task id' >&2; exit 1 ;; esac
[ -d "$STATE" ] || { echo 'error: state directory missing' >&2; exit 1; }
STATE=$(cd "$STATE" && pwd -P)
quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
prefix="$(quote "$SCRIPT_DIR/fm-busy-event.sh") apply $(quote "$STATE") $(quote "$ID")"
suffix="--gen $(quote "$GEN") --source copilot-hook"
submit="$prefix busy $suffix --event user-prompt-submitted >/dev/null 2>&1 || true"
stop="$prefix idle $suffix --event agent-stop >/dev/null 2>&1 && touch $(quote "$STATE/$ID.turn-ended"); true"
end="$prefix idle $suffix --event session-end >/dev/null 2>&1 || true"
dir="$STATE/$ID.copilot-plugin"
umask 077
mkdir -p "$dir"
chmod 700 "$dir"
temp=$(mktemp "$dir/.plugin.XXXXXX")
trap 'rm -f "$temp"' EXIT
jq -n --arg submit "$submit" --arg stop "$stop" --arg end "$end" '
  def hook($cmd): [{type: "command", bash: $cmd, timeoutSec: 10}];
  {
    name: "firstmate-worker",
    version: "1.0.0",
    description: "Firstmate worker lifecycle hooks",
    hooks: {
      userPromptSubmitted: hook($submit),
      agentStop: hook($stop),
      sessionEnd: hook($end)
    }
  }
' > "$temp"
mv "$temp" "$dir/plugin.json"
