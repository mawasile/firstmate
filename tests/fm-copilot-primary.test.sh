#!/usr/bin/env bash
# GitHub Copilot CLI and SDK primary detection, session ownership, and hooks.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-copilot-primary)
HARNESS="$ROOT/bin/fm-harness.sh"
LOCK_LIB="$ROOT/bin/fm-session-lock-lib.sh"
LOCK="$ROOT/bin/fm-lock.sh"

test_copilot_marker_and_runtime_detection() {
  local fakebin runtime got
  fakebin=$(fm_fakebin "$TMP_ROOT/detection")
  cat >"$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *'ppid='*) printf '%s\n' 1 ;;
  *) printf '%s\n' bash ;;
esac
SH
  chmod +x "$fakebin/ps"
  got=$(env -u CLAUDECODE -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
    COPILOT_CLI=1 COPILOT_AGENT_SESSION_ID=copilot-test \
    PATH="$fakebin:/usr/bin:/bin" "$HARNESS")
  [ "$got" = copilot ] || fail "Copilot's marker resolved '$got', expected copilot"

  runtime="$TMP_ROOT/copilot-runtime"
  cp "$(command -v bash)" "$runtime"
  got=$(env -u COPILOT_CLI -u COPILOT_AGENT_SESSION_ID \
    "$runtime" -c "r=\$(\"$HARNESS\"); printf '%s' \"\$r\"")
  [ "$got" = copilot ] || fail "the copilot-runtime process resolved '$got', expected copilot"

  pass "copilot primary: marker and exact runtime ancestry identify Copilot"
}

test_foreign_harness_outranks_copilot_marker() {
  local codex got
  codex="$TMP_ROOT/codex"
  cp "$(command -v bash)" "$codex"
  got=$(COPILOT_CLI=1 COPILOT_AGENT_SESSION_ID=copilot-test \
    "$codex" -c "r=\$(\"$HARNESS\"); printf '%s' \"\$r\"")
  [ "$got" = codex ] \
    || fail "a codex child with inherited Copilot markers resolved '$got', expected codex"
  pass "copilot primary: a nested structural harness outranks inherited markers"
}

test_session_guardian_anchors_logical_lock() {
  local dir runtime driver guardian state home result
  dir="$TMP_ROOT/session-lock"
  runtime="$dir/copilot-runtime"
  driver="$dir/runtime-driver.sh"
  guardian="$dir/guardian.mjs"
  state="$dir/state"
  home="$dir/copilot-home"
  mkdir -p "$state" "$home/session-state/session-one" "$home/session-state/session-two"
  cp "$(command -v bash)" "$runtime"

  cat >"$guardian" <<'JS'
import { spawnSync } from "node:child_process";
import { writeFileSync } from "node:fs";

process.title = "fm-copilot-ses";
const result = spawnSync(process.env.BASH_BIN, [process.env.LOCK], {
  env: {
    ...process.env,
    FM_COPILOT_SESSION_PID: String(process.pid),
  },
  stdio: "inherit",
});
if (result.status !== 0) process.exit(result.status ?? 1);
writeFileSync(process.env.READY, `${process.pid}\n`);
process.on("SIGTERM", () => process.exit(0));
setInterval(() => {}, 1000);
JS

  cat >"$driver" <<'SH'
#!/usr/bin/env bash
set -u
runtime=$$
guardian_pid=
cleanup_guardian() {
  if [ -n "$guardian_pid" ] && kill -0 "$guardian_pid" 2>/dev/null; then
    kill "$guardian_pid" 2>/dev/null || true
    wait "$guardian_pid" 2>/dev/null || true
  fi
}
trap cleanup_guardian EXIT
for id in session-one session-two; do
  dir="$COPILOT_HOME/session-state/$id"
  printf '%s\n' "$runtime" >"$dir/inuse.$runtime.lock"
  : >"$dir/inuse.$runtime.hold"
done

if COPILOT_CLI=1 COPILOT_AGENT_SESSION_ID=session-one \
  bash -c '. "$1"; fm_session_lock_anchor_pid >/dev/null' _ "$LOCK_LIB"; then
  echo "direct runtime unexpectedly became the session anchor" >&2
  exit 1
fi

COPILOT_CLI=1 COPILOT_AGENT_SESSION_ID=session-one \
  node "$GUARDIAN_FIXTURE" &
guardian_pid=$!
for _ in $(seq 1 100); do
  [ -s "$READY" ] && break
  kill -0 "$guardian_pid" 2>/dev/null || break
  sleep 0.02
done
[ -s "$READY" ] || {
  echo "session guardian did not acquire the lock" >&2
  kill "$guardian_pid" 2>/dev/null || true
  wait "$guardian_pid" 2>/dev/null || true
  exit 1
}
recorded=$(cat "$STATE/.lock")
[ "$recorded" = "$guardian_pid" ] || {
  echo "lock recorded '$recorded', expected guardian pid '$guardian_pid'" >&2
  exit 1
}

COPILOT_CLI=1 COPILOT_AGENT_SESSION_ID=session-one \
  bash -c '. "$1"; fm_session_lock_owned_by_self "$2"' _ "$LOCK_LIB" "$STATE" \
  || {
    echo "a sibling tool from the owning logical session did not own the lock" >&2
    exit 1
  }

if COPILOT_CLI=1 COPILOT_AGENT_SESSION_ID=session-two \
  bash -c '. "$1"; fm_session_lock_owned_by_self "$2"' _ "$LOCK_LIB" "$STATE"; then
  echo "a different logical session owned the first session's lock" >&2
  exit 1
fi
COPILOT_CLI=1 COPILOT_AGENT_SESSION_ID=session-two \
  bash -c '. "$1"; fm_session_lock_foreign_owner_live "$2"' _ "$LOCK_LIB" "$STATE" \
  || {
    echo "a different logical session did not classify the live owner as foreign" >&2
    exit 1
  }

kill "$guardian_pid"
wait "$guardian_pid" 2>/dev/null || true
guardian_pid=
bash -c '. "$1"; fm_session_lock_inspect "$2"; [ "$FM_LOCK_INSPECT_STATE" = stale ]' \
  _ "$LOCK_LIB" "$STATE" \
  || {
    echo "the ended guardian did not leave a reclaimable stale lock" >&2
    exit 1
  }
SH
  chmod +x "$driver"

  result=$(STATE="$state" FM_STATE_OVERRIDE="$state" COPILOT_HOME="$home" \
    LOCK_LIB="$LOCK_LIB" LOCK="$LOCK" GUARDIAN_FIXTURE="$guardian" \
    READY="$dir/ready" BASH_BIN="$(command -v bash)" \
    "$runtime" "$driver" 2>&1) \
    || fail "Copilot logical-session lock flow failed: $result"

  pass "copilot primary: the per-session guardian anchors and releases logical ownership"
}

test_hook_transports_startup_pretool_and_stop() {
  local dir runtime hook output start_log payload
  dir="$TMP_ROOT/hooks"
  runtime="$dir/copilot-runtime"
  hook="$dir/bin/fm-copilot-hook.sh"
  output="$dir/output"
  start_log="$dir/start.log"
  mkdir -p "$dir/bin" "$dir/state" "$dir/copilot/session-state/sdk-session"
  git init -q "$dir"
  cp "$(command -v bash)" "$runtime"
  cp \
    "$ROOT/bin/fm-copilot-hook.sh" \
    "$ROOT/bin/fm-copilot-lib.sh" \
    "$ROOT/bin/fm-copilot-session.mjs" \
    "$ROOT/bin/fm-cursor-lib.sh" \
    "$ROOT/bin/fm-session-lock-lib.sh" \
    "$dir/bin/"

  cat >"$dir/bin/fm-sessionstart-run.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$COPILOT_AGENT_SESSION_ID" "$FM_COPILOT_SESSION_PID" >"$FM_TEST_START_LOG"
printf '%s\n' 'COPILOT START CONTEXT'
SH
  cat >"$dir/bin/fm-arm-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *' denied-command '*)
    printf '%s\n' '{"systemMessage":"copilot pretool denied"}' >&2
    exit 2
    ;;
esac
exit 0
SH
  for script in fm-cd-pretool-check.sh fm-subagent-pretool-check.sh; do
    cat >"$dir/bin/$script" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  done
  cat >"$dir/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' 'watcher missing' >&2
exit 2
SH
  cat >"$dir/bin/fm-operational-input.sh" <<'SH'
#!/usr/bin/env bash
[ "$1" = encode ] || exit 1
printf 'ENCODED:%s:%s\n' "$2" "$3"
SH
  chmod +x "$dir/bin/"*.sh "$dir/bin/"*.mjs

  run_runtime_hook() {  # <operation> <payload>
    local operation=$1 hook_payload=$2
    # shellcheck disable=SC2016 # PAYLOAD and HOOK expand inside the named runtime process.
    FM_ROOT_OVERRIDE="$dir" FM_HOME="$dir" COPILOT_HOME="$dir/copilot" \
      FM_TEST_START_LOG="$start_log" HOOK="$hook" PAYLOAD="$hook_payload" \
      "$runtime" -c 'printf "%s" "$PAYLOAD" | "$HOOK" "$1"' _ "$operation"
  }

  payload=$(jq -nc --arg cwd "$dir" '{sessionId:"sdk-session",source:"startup",cwd:$cwd}')
  output=$(run_runtime_hook session-start "$payload") \
    || fail "Copilot session-start hook failed"
  printf '%s' "$output" | jq -e '.additionalContext == "COPILOT START CONTEXT"' >/dev/null \
    || fail "Copilot session-start hook did not return additional context: $output"
  awk -F '\t' '
    $1 == "--source" && $2 == "startup" && $3 == "sdk-session" && $4 ~ /^[0-9]+$/ { ok=1 }
    END { exit ok ? 0 : 1 }
  ' "$start_log" \
    || fail "Copilot session-start hook did not pass its logical session and guardian pid"

  payload=$(jq -nc --arg cwd "$dir" '{sessionId:"sdk-session",cwd:$cwd,toolName:"bash",toolArgs:{command:"denied-command"}}')
  output=$(run_runtime_hook pre-tool "$payload") \
    || fail "Copilot pre-tool hook failed"
  printf '%s' "$output" | jq -e '
    .permissionDecision == "deny"
    and .permissionDecisionReason == "copilot pretool denied"
  ' >/dev/null \
    || fail "Copilot pre-tool hook did not return the native deny object: $output"

  payload=$(jq -nc --arg cwd "$dir" '{sessionId:"sdk-session",cwd:$cwd,stop_hook_active:false}')
  output=$(run_runtime_hook agent-stop "$payload") \
    || fail "Copilot agent-stop hook failed"
  printf '%s' "$output" | jq -e '
    .decision == "block"
    and (.reason | startswith("ENCODED:turn-end-guard:TURN WOULD END BLIND"))
  ' >/dev/null \
    || fail "Copilot agent-stop hook did not return the bounded block decision: $output"

  payload=$(jq -nc --arg cwd "$dir" '{sessionId:"sdk-session",cwd:$cwd,reason:"user_exit"}')
  run_runtime_hook session-end "$payload" >/dev/null \
    || fail "Copilot session-end hook failed"

  pass "copilot primary: hooks deliver startup, pre-tool denial, bounded stop, and cleanup"
}

test_scoped_hook_installer_and_out_of_scope_noop() {
  local dir other hook_file output payload
  dir="$TMP_ROOT/installer/home"
  other="$TMP_ROOT/installer/other"
  hook_file="$TMP_ROOT/installer/copilot/firstmate.json"
  mkdir -p "$dir/bin" "$dir/state" "$other"
  git init -q "$dir"
  git init -q "$other"
  cp "$ROOT/bin/fm-copilot-hook.sh" "$dir/bin/fm-copilot-hook.sh"

  FM_ROOT_OVERRIDE="$dir" FM_HOME="$dir" FM_COPILOT_HOOK_FILE="$hook_file" \
    bash "$ROOT/bin/fm-copilot-hook-install.sh" >/dev/null \
    || fail "Copilot hook installer failed"
  jq -e '
    .version == 1
    and (.hooks.sessionStart[0].bash | contains("fm-copilot-hook.sh"))
    and (.hooks.preToolUse[0].bash | contains("pre-tool"))
    and (.hooks.agentStop[0].bash | contains("agent-stop"))
    and (.hooks.sessionEnd[0].bash | contains("session-end"))
  ' "$hook_file" >/dev/null \
    || fail "Copilot hook installer did not publish the four scoped events"

  payload=$(jq -nc --arg cwd "$other" '{sessionId:"other-session",source:"startup",cwd:$cwd}')
  output=$(printf '%s' "$payload" | FM_ROOT_OVERRIDE="$dir" FM_HOME="$dir" \
    bash "$dir/bin/fm-copilot-hook.sh" session-start) \
    || fail "out-of-scope Copilot hook invocation failed"
  [ "$output" = "{}" ] \
    || fail "out-of-scope Copilot hook invocation was not inert: $output"
  [ ! -e "$dir/state/copilot-sessions/other-session.owner" ] \
    || fail "out-of-scope Copilot hook created a guardian record"

  pass "copilot primary: installer scopes user hooks to one Firstmate home"
}

test_copilot_marker_and_runtime_detection
test_foreign_harness_outranks_copilot_marker
test_session_guardian_anchors_logical_lock
test_hook_transports_startup_pretool_and_stop
test_scoped_hook_installer_and_out_of_scope_noop
