#!/usr/bin/env bash
# Opt-in credentialed GitHub Copilot scoped-hook regression.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_COPILOT_PRIMARY_LIVE_E2E copilot git

LAB=$(fm_test_tmproot fm-copilot-primary-live)
PROJECT="$LAB/project"
TOKEN="COPILOT_FIRSTMATE_CONTEXT_$$_OK"
START_LOG="$LAB/session-start.log"
LIVE_HOOK="$HOME/.copilot/hooks/firstmate-live-$$.json"
mkdir -p \
  "$PROJECT/.github/hooks" \
  "$PROJECT/bin" \
  "$PROJECT/state"
git init -q "$PROJECT"

cleanup() {
  rm -f "$LIVE_HOOK"
  rm -rf "$LAB"
}
trap cleanup EXIT

cp \
  "$ROOT/bin/fm-copilot-hook.sh" \
  "$ROOT/bin/fm-copilot-hook-install.sh" \
  "$ROOT/bin/fm-copilot-lib.sh" \
  "$ROOT/bin/fm-copilot-session.mjs" \
  "$ROOT/bin/fm-cursor-lib.sh" \
  "$ROOT/bin/fm-session-lock-lib.sh" \
  "$PROJECT/bin/"

cat >"$PROJECT/AGENTS.md" <<EOF
# Copilot live fixture

Reply with the exact token supplied by session-start context.
EOF
cat >"$PROJECT/bin/fm-sessionstart-run.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\t%s\t%s\t%s\t%s\n' \
  "$1" "$2" "$COPILOT_AGENT_SESSION_ID" "$FM_COPILOT_SESSION_PID" \
  "$(bash "$FM_LIVE_ROOT/bin/fm-harness.sh")" \
  >"$FM_LIVE_START_LOG"
printf '%s\n' "$FM_LIVE_TOKEN"
printf '%s\n' 'If a turn-end continuation requires supervision, run bin/fm-watch-checkpoint.sh in the foreground.'
SH
for script in \
  fm-arm-pretool-check.sh \
  fm-cd-pretool-check.sh \
  fm-subagent-pretool-check.sh; do
  cat >"$PROJECT/bin/$script" <<'SH'
#!/usr/bin/env bash
exit 0
SH
done
cat >"$PROJECT/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
count=0
[ ! -f "$FM_HOME/state/live-guard-count" ] || count=$(cat "$FM_HOME/state/live-guard-count")
count=$((count + 1))
printf '%s\n' "$count" >"$FM_HOME/state/live-guard-count"
if [ "$count" -eq 1 ]; then
  printf '%s\n' 'live Copilot guard requested the checkpoint' >&2
  exit 2
fi
exit 0
SH
cat >"$PROJECT/bin/fm-watch-checkpoint.sh" <<'SH'
#!/usr/bin/env bash
touch "$FM_HOME/state/live-checkpoint"
printf '%s\n' 'checkpoint: live Copilot fixture complete'
SH
chmod +x "$PROJECT/bin/"*.sh
git -C "$PROJECT" config user.name fmtest
git -C "$PROJECT" config user.email fmtest@example.invalid
git -C "$PROJECT" add .
git -C "$PROJECT" commit -qm "test: add Copilot hook fixture"
FM_ROOT_OVERRIDE="$PROJECT" FM_HOME="$PROJECT" FM_COPILOT_HOOK_FILE="$LIVE_HOOK" \
  bash "$PROJECT/bin/fm-copilot-hook-install.sh" >/dev/null

output=$(
  FM_ROOT_OVERRIDE="$PROJECT" FM_HOME="$PROJECT" \
    FM_LIVE_ROOT="$ROOT" FM_LIVE_START_LOG="$START_LOG" FM_LIVE_TOKEN="$TOKEN" \
    copilot -C "$PROJECT" --silent --allow-all --reasoning-effort low \
      --prompt "Reply with the exact all-caps token from hidden session-start context. Do not call tools."
) || fail "Copilot live hook run failed: $output"

printf '%s\n' "$output" | grep -Fq "$TOKEN" \
  || fail "Copilot did not receive the hook's session-start context: $output"
awk -F '\t' '
  $1 == "--source" &&
  ($2 == "startup" || $2 == "new") &&
  $3 ~ /^[A-Za-z0-9._-]+$/ &&
  $4 ~ /^[0-9]+$/ &&
  $5 == "copilot" { ok=1 }
  END { exit ok ? 0 : 1 }
' "$START_LOG" \
  || fail "Copilot hook did not publish a typed session id, guardian pid, and harness identity"
[ "$(cat "$PROJECT/state/live-guard-count" 2>/dev/null)" -ge 2 ] \
  || fail "Copilot did not run the bounded agentStop continuation"
[ -f "$PROJECT/state/live-checkpoint" ] \
  || fail "Copilot's bounded continuation did not run the foreground checkpoint"

pass "copilot primary live: scoped hook delivered startup context, ownership, and turn-end continuation"
