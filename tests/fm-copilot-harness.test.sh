#!/usr/bin/env bash
# Portable GitHub Copilot CLI worker adapter regression. Vendor facts are
# refreshed by fm-copilot-signals-live-e2e.test.sh; this suite needs no
# Copilot credentials and never launches Copilot.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$ROOT/bin/fm-composer-lib.sh"
# shellcheck source=bin/fm-agent-process-lib.sh
. "$ROOT/bin/fm-agent-process-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-copilot-harness)
unset CLAUDECODE PI_CODING_AGENT GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS GEMINI_CLI FM_OMP_HARNESS ATLASSIAN_AGENT_TYPE ROVODEV_CLI \
  COPILOT_CLI COPILOT_AGENT_SESSION_ID FM_COPILOT_SESSION_PID

engine=/usr/lib/node_modules/@github/copilot/node_modules/@github/copilot-linux-x64/copilot
[ "$(fm_agent_process_classify_name '' "$engine")" = agent ] || fail 'liveness lost the Copilot engine argv[0]'
[ "$(fm_agent_process_classify_name copilot)" = agent ] || fail 'liveness lost an exact copilot name'
[ "$(fm_agent_process_classify_name MainThread node)" = other ] || fail 'the generic MainThread name claimed an agent'
for decoy in copilot-runtime copilot-helper; do
  [ "$(fm_agent_process_classify_name "$decoy")" = other ] || fail "liveness claimed unrelated $decoy"
  [ "$(fm_agent_process_classify_name '' "/opt/bin/$decoy")" = other ] || fail "liveness claimed unrelated $decoy argv[0]"
done
[ "$(fm_control_harness_family copilot)" = copilot ] || fail 'recorded copilot did not resolve to its adapter'
! fm_control_harness_family copilot-runtime >/dev/null || fail 'the SDK host name resolved to the worker adapter'
pass "Copilot anchored liveness identity and exact adapter family"

fm_control_harness_supported copilot || fail 'copilot is not a verified control harness'
[ "$(fm_control_interrupt_key copilot)" = Escape ] || fail 'wrong interrupt key'
[ "$(fm_control_interrupt_repeat copilot)" = 2 ] || fail 'Copilot needs a double Escape'
[ "$(fm_control_interrupt_arm_signal copilot)" = 'esc again to interrupt' ] || fail 'second press must wait for the running-turn proof'
[ "$(fm_control_interrupt_press_gap copilot)" = 0.2 ] || fail 'press gap must stay inside the 0.6 s armed window'
hazard=$(fm_control_interrupt_hazard_signal copilot)
for row in 'Rewind to a previous point' '↑↓ Navigate · Enter Select · Esc Cancel'; do
  printf '%s\n' "$row" | grep -Eq -- "$hazard" || fail "rewind picker row not recognized: $row"
done
! printf '%s\n' 'esc again to rewind' | grep -Eq -- "$hazard" || fail 'the idle arm hint is not the picker'
[ -z "$(fm_control_interrupt_clear_key copilot)" ] || fail 'Copilot must not erase a composer draft'
[ "$(fm_control_exit_command copilot)" = /exit ] || fail 'wrong exit command'
fm_control_harness_supports_kind copilot ship || fail 'ship refused'
fm_control_harness_supports_kind copilot scout || fail 'scout refused'
! fm_control_harness_supports_kind copilot secondmate || fail 'secondmate accepted'
pass "worker-only lifecycle capabilities with an armed double Escape"

for signal in '◎ Working · 108 B esc interrupt' '● Working esc edit prompt' '◉ Working · 110 B esc again to interrupt'; do
  printf '%s\n' "$signal" | fm_busy_lines_match copilot || fail "delivery signal lost: $signal"
  printf '%s\n' "$signal" | FM_BUSY_REGEX='' fm_busy_lines_match || fail "harness-less union lost: $signal"
done
printf '%s\n' ' ○ Working · 2.0 KiB' | fm_busy_lines_match copilot || fail 'spinner row alone lost'
for quiet in ' ← open sidebar · Interactive · Allow All · / commands · ? help · tab next tab' \
  ' ● Working on the fix now.' '❯ unsubmitted draft' 'esc twice to interrupt'; do
  ! printf '%s\n' "$quiet" | fm_busy_lines_match copilot || fail "not a Copilot busy signal: $quiet"
done
[ "$(fm_composer_classify_content 0 '❯')" = empty ] || fail 'Copilot glyph not recognized'
[ "$(fm_composer_classify_content 0 '❯ unsubmitted draft')" = pending ] || fail 'typed draft not preserved'
pass "independent delivery signals and composer draft safety"

state="$TMP_ROOT/hook state"
mkdir -p "$state"
gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" worker)
"$ROOT/bin/fm-copilot-worker-plugin.sh" "$state" worker "$gen" || fail 'plugin writer failed'
plugin="$state/worker.copilot-plugin/plugin.json"
assert_present "$plugin" 'plugin manifest absent'
[ "$(stat -c %a "$state/worker.copilot-plugin" 2>/dev/null || stat -f %Lp "$state/worker.copilot-plugin")" = 700 ] \
  || fail 'plugin directory is not private'
[ "$(stat -c %a "$plugin" 2>/dev/null || stat -f %Lp "$plugin")" = 600 ] || fail 'plugin manifest is not private'
jq -e '(.name | type) == "string" and (has("version") and (.hooks | has("version") | not))' "$plugin" >/dev/null \
  || fail 'hooks must be inline without the version wrapper Copilot ignores'
jq -e '[.hooks.userPromptSubmitted, .hooks.agentStop, .hooks.sessionEnd][] | (length == 1 and .[0].type == "command")' "$plugin" >/dev/null \
  || fail 'lifecycle hooks missing'
run_hook() { bash -c "$(jq -r --arg event "$1" '.hooks[$event][0].bash' "$plugin")"; }
run_hook userPromptSubmitted
[ "$(fm_busy_classify tmux fake:w copilot worker "$state")" = 'busy copilot-hook' ] || fail 'prompt did not open busy'
run_hook agentStop
[ "$(fm_busy_classify tmux fake:w copilot worker "$state")" = 'idle copilot-hook' ] || fail 'agentStop did not settle'
assert_present "$state/worker.turn-ended" 'agentStop notification absent'
run_hook userPromptSubmitted
run_hook sessionEnd
[ "$(fm_busy_classify tmux fake:w copilot worker "$state")" = 'idle copilot-hook' ] || fail 'sessionEnd did not settle'
"$ROOT/bin/fm-busy-event.sh" arm "$state" worker >/dev/null
rm "$state/worker.turn-ended"
run_hook agentStop
[ "$(fm_busy_classify tmux fake:w copilot worker "$state")" = 'busy fm-spawn' ] || fail 'stale agentStop cleared replacement'
assert_absent "$state/worker.turn-ended" 'stale agentStop woke replacement'
[ "$(fm_control_harness_wiring_paths copilot /unused "$state" worker)" = "$plugin" ] || fail 'manifest retirement missing'
! "$ROOT/bin/fm-copilot-worker-plugin.sh" "$state" 'bad/id' "$gen" 2>/dev/null || fail 'invalid task id accepted'
"$ROOT/bin/fm-busy-event.sh" apply "$state" worker idle --current-gen --source devin-hook --event stop >/dev/null 2>&1 \
  || fail 'could not write a foreign-source record'
[ "$(fm_busy_classify tmux fake:w copilot worker "$state")" = 'unknown source-mismatch' ] \
  || fail 'another adapter source classified Copilot'
pass "private plugin hooks, stale-generation rejection, and manifest retirement"

case_dir="$TMP_ROOT/spawn"
fakebin=$(make_spawn_fakebin "$case_dir/fake" claude)
fm_fake_exit0 "$fakebin" copilot
home="$case_dir/home"
proj="$case_dir/project"
wt="$case_dir/wt"
fm_test_spawn_home "$home" copilot
fm_git_worktree "$proj" "$wt" copilot-test
fm_test_spawn_brief "$home" copilot-worker
if ! out=$(FM_FAKE_LAUNCH_LOG="$case_dir/launch" \
  fm_test_run_spawn "$home" "$wt" "$fakebin" copilot-worker "$proj" --scout --harness copilot --model gpt-5-mini --effort xhigh 2>&1)
then fail "spawn failed: $out"; fi
launch=$(cat "$case_dir/launch")
assert_contains "$launch" 'COPILOT_ALLOW_ALL=true ' 'workspace trust/autonomy missing'
assert_contains "$launch" ' --allow-all --no-ask-user ' 'autonomy flags missing'
assert_contains "$launch" "--plugin-dir '$home/state/copilot-worker.copilot-plugin'" 'private plugin missing'
assert_contains "$launch" "--model 'gpt-5-mini'" 'model lost'
assert_contains "$launch" "--reasoning-effort 'xhigh'" 'effort lost'
# shellcheck disable=SC2016
assert_contains "$launch" '-i "$(' 'interactive launch prompt missing'
assert_contains "$launch" 'encode launch-brief' 'typed launch envelope lost'
for marker in COPILOT_CLI COPILOT_AGENT_SESSION_ID COPILOT_CLI_RUN_AS_NODE FM_COPILOT_SESSION_PID; do
  assert_contains "$launch" "-u $marker " "primary marker $marker not cleared"
done
assert_grep 'harness=copilot' "$home/state/copilot-worker.meta" 'harness not recorded'
assert_grep 'effort=xhigh' "$home/state/copilot-worker.meta" 'effort not recorded'
assert_present "$home/state/copilot-worker.copilot-plugin/plugin.json" 'spawn did not wire hooks'
[ "$(fm_busy_classify tmux fake:w copilot copilot-worker "$home/state")" = 'busy fm-spawn' ] || fail 'launch not armed'
if out=$(fm_test_run_spawn "$home" "$wt" "$fakebin" copilot-sm "$proj" --secondmate --harness copilot 2>&1)
then fail 'Copilot secondmate launch accepted'; fi
assert_contains "$out" 'cannot run a secondmate' 'wrong secondmate refusal'
pass "scout launch carries autonomy, trust, private hooks, model, effort, and cleared primary markers"
