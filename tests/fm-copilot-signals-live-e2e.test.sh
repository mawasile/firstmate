#!/usr/bin/env bash
# Credentialed GitHub Copilot CLI worker guard. Opt in with
# FM_COPILOT_SIGNALS_LIVE=1. FM_COPILOT_MODEL chooses a Copilot model
# (default claude-haiku-4.5, an inexpensive model that follows the probe's
# multi-step instructions; gpt-5-mini was observed to stop and ask instead).
# Runs the real fm-spawn launch command in a private tmux server; only worktree
# allocation and initial endpoint delivery use fixtures. All later steering,
# interrupt and exit operations use the real Firstmate control plane.
# The pane deliberately inherits this process's environment, so a Copilot
# primary's session markers are present and the launch must clear them. The
# worker keeps the operator's real Copilot sign-in, so HOME is not isolated.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
fm_live_gate opt-in FM_COPILOT_SIGNALS_LIVE copilot tmux jq
COPILOT_BIN=$(command -v copilot)
REAL_TMUX=$(command -v tmux)
VERSION=$(copilot --version 2>/dev/null | head -n 1)
[ -n "$VERSION" ] || VERSION='GitHub Copilot CLI (unknown version)'
MODEL=${FM_COPILOT_MODEL:-claude-haiku-4.5}
LAB=$(mktemp -d "${TMPDIR:-/tmp}/cp.XXXXXX")
LAB=$(cd "$LAB" && pwd -P)
# Unix-domain socket paths have a small OS byte limit. Keep the socket name
# relative when the isolated lab is under this checkout's working directory.
SOCKET="$LAB/tmux.sock"
case "$SOCKET" in "$PWD"/*) SOCKET=${SOCKET#"$PWD"/} ;; esac
cleanup() {
  "$REAL_TMUX" -S "$SOCKET" kill-server >/dev/null 2>&1 || true
  # The spawn-owned commit-msg strip directory is left read-only.
  chmod -R u+w "$LAB" 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT
fail() { printf 'not ok - %s: %s\n' "$VERSION" "$1" >&2; exit 1; }
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$ROOT/bin/fm-composer-lib.sh"
H="$LAB/home"
WT="$LAB/wt"
PROJ="$LAB/project"
ID=copilot-live
PRIMARY_SESSION=fm-copilot-live-primary-marker
fm_test_spawn_home "$H" copilot
fm_git_worktree "$PROJ" "$WT" copilot-live
mkdir -p "$LAB/bin"
git -C "$WT" config user.name 'Copilot Live Guard'
git -C "$WT" config user.email copilot-live-guard@example.invalid
fm_test_spawn_brief "$H" "$ID" "Runtime verification only: compute 12345 plus 67890 using your shell tool and write only the result into answer.txt, then commit answer.txt with git using a commit message you write yourself. Also run '$ROOT/bin/fm-harness.sh' and write its output to harness.txt, and run 'printenv COPILOT_AGENT_SESSION_ID' and write its output to session.txt. Do no other work and do not delegate. Later read and acknowledge Firstmate's instruction inbox when the doorbell arrives."
fakebin=$(make_spawn_fakebin "$LAB/fake" claude)
ln -s "$COPILOT_BIN" "$fakebin/copilot"
FM_FAKE_LAUNCH_LOG="$LAB/launch.sh" fm_test_run_spawn "$H" "$WT" "$fakebin" "$ID" "$PROJ" \
  --scout --harness copilot --model "$MODEL" --effort high > "$LAB/spawn.log" 2>&1 \
  || fail "fm-spawn failed: $(cat "$LAB/spawn.log")"
# Route every backend read/write to this guard's own socket only.
printf '#!/bin/sh\nexec "%s" -S "%s" "$@"\n' "$REAL_TMUX" "$SOCKET" > "$LAB/bin/tmux"
chmod +x "$LAB/bin/tmux"
export PATH="$LAB/bin:$PATH" FM_HOME="$H"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
TARGET="firstmate:fm-$ID"
COPILOT_CLI=1 COPILOT_AGENT_SESSION_ID=$PRIMARY_SESSION COPILOT_CLI_RUN_AS_NODE=1 \
  "$REAL_TMUX" -S "$SOCKET" new-session -d -s firstmate -n "fm-$ID" -x 160 -y 50 -c "$WT" \
  "/bin/sh '$LAB/launch.sh'; exec /bin/bash --noprofile --norc" || fail 'could not start pane'
capture() { "$REAL_TMUX" -S "$SOCKET" capture-pane -p -e -t "$TARGET"; }
screen_text() { "$REAL_TMUX" -S "$SOCKET" capture-pane -p -t "$TARGET"; }
# The delivery footer read production performs (bin/fm-tmux-lib.sh's
# fm_pane_busy_state): plain text, last 12 non-blank lines.
rendered_busy() { screen_text | grep -v '^[[:space:]]*$' | tail -12 | fm_busy_lines_match copilot; }
wait_file() {
  local path=$1 i
  for i in $(seq 1 480); do [ -s "$path" ] && return 0; sleep 0.5; done
  fail "timed out waiting for ${path##*/}; screen: $(screen_text | grep -v '^[[:space:]]*$' | tail -n 8)"
}
wait_idle() {
  local i
  for i in $(seq 1 240); do
    [ "$(fm_busy_classify tmux "$TARGET" copilot "$ID" "$H/state")" = 'idle copilot-hook' ] && return 0
    sleep 0.5
  done
  fail "agentStop did not produce semantic idle: $(fm_busy_classify tmux "$TARGET" copilot "$ID" "$H/state")"
}
wait_file "$WT/answer.txt"
wait_file "$WT/harness.txt"
wait_file "$WT/session.txt"
[ "$(tr -d '[:space:]' < "$WT/answer.txt")" = 80235 ] || fail 'launch brief did not execute'
[ "$(tr -d '[:space:]' < "$WT/harness.txt")" = copilot ] || fail 'tool marker did not identify Copilot'
worker_session=$(tr -d '[:space:]' < "$WT/session.txt")
[ -n "$worker_session" ] && [ "$worker_session" != "$PRIMARY_SESSION" ] \
  || fail "the worker kept the primary's Copilot session marker: '$worker_session'"
wait_idle
[ -f "$H/state/$ID.turn-ended" ] || fail 'agentStop did not notify turn end'
[ "$(fm_backend_agent_state tmux "$TARGET")" = alive ] || fail 'real Copilot process not classified alive'
pass "$VERSION: spawn brief, model, autonomy, trust, own session identity and native agentStop"
git -C "$WT" log -1 --format=%B -- answer.txt > "$LAB/commit.txt" 2>/dev/null
[ -s "$LAB/commit.txt" ] || fail 'the worker did not commit answer.txt'
! grep -qiE 'co-authored-by:.*copilot|generated (with|by) .*copilot' "$LAB/commit.txt" \
  || fail "worker commit carries Copilot attribution: $(cat "$LAB/commit.txt")"
pass "$VERSION: the worker commit carries no Copilot attribution"
# The full styled screen, not an invented glyph-only fixture, must be safe to type into.
verdict=$(fm_composer_classify_screen $'styled=1\ncursor=1\nidentity=1\nrows=0' "$(capture)" \
  "$(tmux display-message -p -t "$TARGET" '#{cursor_y}')" copilot)
case "$verdict" in empty*) ;; *) fail "idle composer was $verdict" ;; esac
"$ROOT/bin/fm-send.sh" "$ID" "Runtime steering verification: compute 31 times 37 and write only the result to the file '$WT/steer.txt'. Acknowledge this instruction by moving its .msg file into handled/ as instructed by the doorbell. Do no other work." > "$LAB/send.log" 2>&1 || fail "steer failed: $(cat "$LAB/send.log")"
wait_file "$WT/steer.txt"
wait_file "$H/state/$ID.inbox/handled/001.msg"
[ "$(tr -d '[:space:]' < "$WT/steer.txt")" = 1147 ] || fail 'wrong steering result'
wait_idle
pass "$VERSION: real fm-send doorbell read and acknowledged"
# An idle Copilot opens its rewind picker (Enter rewinds) on a fast Escape
# pair, so an interrupt with no running turn must send one press and open nothing.
"$ROOT/bin/fm-control.sh" "$ID" interrupt > "$LAB/idle-interrupt.log" 2>&1 \
  || fail "idle interrupt failed: $(cat "$LAB/idle-interrupt.log")"
grep -q 'cancel=not-running' "$LAB/idle-interrupt.log" \
  || fail "idle interrupt did not report not-running: $(cat "$LAB/idle-interrupt.log")"
sleep 1.5
! screen_text | grep -q 'Rewind to a previous point' || fail 'idle interrupt opened the rewind picker'
# The hazard is real on this version: a raw fast pair opens the picker. Two
# presses with no gap at all arrive as one Alt+Escape sequence, so the probe
# leaves the 0.1 s gap that paired them in the live capture. Exit must refuse
# to type into it and interrupt must close it with no rewind.
picker=0
for _ in 1 2 3; do
  tmux send-keys -t "$TARGET" Escape
  sleep 0.1
  tmux send-keys -t "$TARGET" Escape
  sleep 1
  if screen_text | grep -q 'Rewind to a previous point'; then picker=1; break; fi
  sleep 1
done
[ "$picker" = 1 ] || fail 'a raw fast Escape pair no longer opens the rewind picker; re-verify the interrupt arm gate'
if "$ROOT/bin/fm-control.sh" "$ID" exit > "$LAB/picker-exit.log" 2>&1; then
  fail "exit proceeded with the rewind picker open: $(cat "$LAB/picker-exit.log")"
fi
screen_text | grep -q 'Rewind to a previous point' || fail 'the refused exit closed or typed into the picker'
"$ROOT/bin/fm-control.sh" "$ID" interrupt > "$LAB/picker-interrupt.log" 2>&1 \
  || fail "interrupt could not close the rewind picker: $(cat "$LAB/picker-interrupt.log")"
sleep 1
! screen_text | grep -q 'Rewind to a previous point' || fail 'interrupt left the rewind picker open'
[ "$(tr -d '[:space:]' < "$WT/steer.txt")" = 1147 ] && [ "$(tr -d '[:space:]' < "$WT/answer.txt")" = 80235 ] \
  || fail 'the rewind picker changed the worker files'
pass "$VERSION: idle interrupt sends one press; an open rewind picker blocks exit and is closed without rewinding"
# The edit-prompt hazard behind the interrupt's defer phase is real on this
# version: a pair pressed before output streams cancels the turn and restores
# its prompt (here the one-line steering doorbell) into the composer.
"$ROOT/bin/fm-send.sh" "$ID" 'Runtime edit-phase verification: reply with exactly EDITPHASE.' > "$LAB/send.log" 2>&1 || fail 'could not steer edit-phase probe'
edit_phase=0
for _ in $(seq 1 300); do
  if screen_text | grep -v '^[[:space:]]*$' | tail -n 1 | grep -q 'esc edit prompt'; then edit_phase=1; break; fi
  sleep 0.05
done
[ "$edit_phase" = 1 ] || fail 'the turn never showed its esc edit prompt phase; re-verify the interrupt defer signal'
tmux send-keys -t "$TARGET" Escape
sleep 0.15
tmux send-keys -t "$TARGET" Escape
sleep 1.5
verdict=$(fm_composer_classify_screen $'styled=1\ncursor=1\nidentity=1\nrows=0' "$(capture)" \
  "$(tmux display-message -p -t "$TARGET" '#{cursor_y}')" copilot)
[ "$verdict" = pending ] || fail "an edit-phase Escape pair no longer restores the prompt (composer $verdict); re-verify the interrupt defer signal"
tmux send-keys -t "$TARGET" C-u
sleep 0.5
verdict=$(fm_composer_classify_screen $'styled=1\ncursor=1\nidentity=1\nrows=0' "$(capture)" \
  "$(tmux display-message -p -t "$TARGET" '#{cursor_y}')" copilot)
[ "$verdict" = empty ] || fail "the restored one-line doorbell did not clear (composer $verdict)"
pass "$VERSION: an Escape pair in the edit-prompt phase restores the prompt, which the interrupt's defer phase avoids"
"$ROOT/bin/fm-send.sh" "$ID" 'Runtime interrupt verification: run sleep 90 in your shell tool in the foreground and wait for it to finish. Do not respond before it finishes.' > "$LAB/send.log" 2>&1 || fail 'could not steer interrupt probe'
seen_busy=0
for _ in $(seq 1 240); do
  if [ "$(fm_busy_classify tmux "$TARGET" copilot "$ID" "$H/state")" = 'busy copilot-hook' ] \
    && rendered_busy; then seen_busy=1; break; fi
  sleep 0.5
done
[ "$seen_busy" = 1 ] || fail "no semantic and rendered busy during interrupt probe: state=$(fm_busy_classify tmux "$TARGET" copilot "$ID" "$H/state") footer=$(screen_text | grep -v '^[[:space:]]*$' | tail -n 1)"
"$ROOT/bin/fm-control.sh" "$ID" interrupt > "$LAB/interrupt.log" 2>&1 || fail "interrupt failed: $(cat "$LAB/interrupt.log")"
grep -q 'cancel=unconfirmed' "$LAB/interrupt.log" || fail "busy interrupt was not armed: $(cat "$LAB/interrupt.log")"
[ "$(fm_busy_classify tmux "$TARGET" copilot "$ID" "$H/state")" = 'unknown fm-interrupt' ] || fail 'interrupt did not conservatively invalidate state'
for _ in $(seq 1 60); do
  screen_text | grep -q 'Operation cancelled by user' && break
  sleep 0.5
done
screen_text | grep -q 'Operation cancelled by user' || fail 'armed double Escape did not cancel'
pass "$VERSION: armed double Escape cancels, preserves agent, and invalidates busy state"
"$ROOT/bin/fm-control.sh" "$ID" exit > "$LAB/exit.log" 2>&1 || fail "exit failed: $(cat "$LAB/exit.log")"
[ "$(fm_backend_agent_state tmux "$TARGET")" = dead ] || fail '/exit did not return to shell'
# Native resume is a vendor fact, not a new fm-control verb.
printf '%s\n' "exec env COPILOT_ALLOW_ALL=true '$COPILOT_BIN' --allow-all --no-ask-user --plugin-dir '$H/state/$ID.copilot-plugin' --model '$MODEL' --resume='$worker_session' -i 'Runtime resume probe: write the product of 17 and 29 into the file $WT/resumed.txt, then stop.'" > "$LAB/resume.sh"
tmux send-keys -t "$TARGET" -l "sh '$LAB/resume.sh'"
sleep 0.5
tmux send-keys -t "$TARGET" Enter
wait_file "$WT/resumed.txt"
[ "$(tr -d '[:space:]' < "$WT/resumed.txt")" = 493 ] || fail 'resume prompt not processed'
# Exit retired the busy generation, so the resumed session's hooks are stale by
# design; wait for the rendered turn to end instead of a semantic idle.
for _ in $(seq 1 120); do
  rendered_busy || break
  sleep 0.5
done
"$ROOT/bin/fm-control.sh" "$ID" exit > "$LAB/exit.log" 2>&1 || fail "resumed exit failed: $(cat "$LAB/exit.log")"
pass "$VERSION: /exit and native --resume session resume"
