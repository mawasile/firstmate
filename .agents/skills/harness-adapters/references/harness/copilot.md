# GitHub Copilot CLI and SDK

## Support boundary

GitHub Copilot CLI and the VS Code Copilot SDK host are verified for the primary Firstmate session.
GitHub Copilot CLI is also verified as a crewmate and scout adapter, verified on 2026-10-14 with Copilot CLI 1.0.97.
A secondmate launch is not verified: the primary integration is a user-level hook registration scoped to one home, not a launch a parent can stand up, so `bin/fm-spawn.sh` refuses `--secondmate` on Copilot.
[Worker verification evidence](../../../../../docs/verification/copilot.md) and its live guard refresh the worker facts below.

## Detection and session ownership

`bin/fm-harness.sh` identifies Copilot from the exact `copilot`, `copilot-runtime`, or `fm-copilot-ses` process names.
Tool subprocesses also carry `COPILOT_CLI=1` and a valid `COPILOT_AGENT_SESSION_ID`.
Structural ancestry wins over inherited markers when another harness runs beneath Copilot.

The VS Code host shares one `copilot-runtime` process across logical chats, so that process never anchors the Firstmate session lock.
The tracked session-start hook creates a guardian with the process title `fm-copilot-ses`, passes its pid to session start, and makes it the per-session anchor.
Ordinary tool subprocesses prove the same logical session with `COPILOT_AGENT_SESSION_ID` and Copilot's session-specific in-use record while the guardian pid remains live.

## Primary hooks

`bin/fm-copilot-hook-install.sh` installs this home's scoped registration under `$COPILOT_HOME/hooks/`.
Its `sessionStart` command returns the ordered Firstmate digest as `additionalContext`.
Its `preToolUse` command applies the watcher-arm, persistent-directory, and built-in-delegation protections.
Copilot also loads the project `.claude/settings.json` PreToolUse hooks, and when one of those denies, Copilot shows only `Denied by preToolUse hook: hook exited with code 2` and drops the stderr reason.
That bare message on a bash call usually means the persistent-directory guard rejected a top-level `cd`, including `cd <dir> && <cmd>`, so never start a Copilot primary command with `cd`.
Reach the target with an absolute path or `git -C <dir>`, or scope the change in a subshell like `(cd <dir> && ...)`; `../../../../../docs/cd-guard.md` owns the full block and allow rules.

The `agentStop` hook uses Copilot's native block decision for one bounded continuation when supervision is required.
The continuation follows the rendered foreground-checkpoint protocol, matching Codex's watcher shape without depending on background completion notifications.
The `sessionEnd` hook retires the logical-session guardian.

Those user-level hooks also fire for a Copilot worker run by the same user, and they answer `{}` because the worker's working tree is not this home.

## Worker operating facts

| Fact | Value |
|---|---|
| Launch | `copilot -i <typed launch envelope>` with `COPILOT_ALLOW_ALL=true`, `--allow-all`, `--no-ask-user`, and `--plugin-dir` for the private hook plugin; `../../../../../bin/fm-spawn.sh` owns the exact command. |
| Trust dialogs | Only the exact `COPILOT_ALLOW_ALL=true` spelling trusts the fresh worktree; without it a "Confirm folder trust" dialog parks the launch even under `--allow-all`. |
| Busy state | `userPromptSubmitted` opens, `agentStop` closes normal completion, and `sessionEnd` closes shutdown through the generation-bound writer; `../../../bin/fm-busy-lib.sh` owns trust. |
| Hook wiring | A per-task legacy plugin with inline hooks, written by `../../../../../bin/fm-copilot-worker-plugin.sh`; no user, project, or global Copilot config is edited. |
| Exit command | `/exit`, with the shared slash-command settle before Enter; prints `copilot --resume=<session-id>`. A slash command typed during a running turn is queued until the turn ends. |
| Interrupt | Esc twice, the second press only after the running turn renders `esc again to interrupt` (an armed window of about 0.6 seconds), with no clear key. The first press waits for the turn to leave its `esc edit prompt` phase. An idle agent gets one press and `cancel=not-running`. |
| Resume | `copilot --resume=<session-id>`; Firstmate relaunch uses the instructions on disk instead. |
| Skill invocation | No separate verified form; use natural language when the exact command form is uncertain. |
| Model flag | `--model <model-id>`; `copilot help config` lists the account's models under `model`. |
| Effort flag | `--reasoning-effort <level>` for low, medium, high, xhigh, or max; an effort the model does not support prints a warning and runs at the model default. |
| Liveness identity | The kernel process name is `MainThread` for both the node launcher and the native engine, so the engine's argv[0] ending in `copilot` identifies the worker. |
| Marker | `COPILOT_CLI=1` and the worker's own `COPILOT_AGENT_SESSION_ID`; the launch clears a Copilot primary's markers first. |
| Commit attribution | No Copilot trailer reached the verified worker commit; the shared AI-trailer strip hook still applies. |

## Worker lifecycle limits

An armed double Esc prints `Operation cancelled by user` above an empty composer but emits no `agentStop` hook on this version.
The control plane therefore invalidates the interrupted incarnation to `unknown`, with `cancel=unconfirmed`; it never fabricates semantic idle from a delivered key.

A turn opens in an `esc edit prompt` phase until output streams.
A pair pressed there cancels the turn and restores the whole prompt into the composer, where a multi-line launch brief cannot be cleared with one line-clear key.
The control plane waits for that phase to clear before its first press and refuses with no key sent if it does not clear in time.

An idle Esc renders `esc again to rewind`, and a fast idle pair opens the "Rewind to a previous point" picker, where Enter rewinds the session.
An open picker is closed with one Esc, never Enter; the control plane does that after its own presses and refuses to type an exit command into it.

A model may run a long shell command in the background and end its turn; the command's completion then starts a new turn with its own `userPromptSubmitted`.

## Composer and steering

`../../../../../bin/fm-composer-lib.sh` owns the verified `❯` glyph, which sits alone between two solid rules with no placeholder, and the busy footer signals.
The logo row `╭─╮╭─╮` is glyph art rather than a box edge, so the composer below it reads normally.
A message submitted during a running turn is accepted at once and the composer clears.
The `../../../../../bin/fm-task-inbox-lib.sh` doorbell was read and acknowledged through real `fm-send`.

## Model, effort, and dispatch

The captain selects the primary Copilot model and effort through Copilot's own surface.
Firstmate does not translate the primary's settings into worker launch flags; a worker receives only the concrete axes chosen at intake.
Copilot routes several model families through one GitHub account, so a typed dispatch profile must declare its `provider` explicitly.

## Verification

Run `bash tests/fm-copilot-primary.test.sh` for portable primary detection, ownership, startup, pre-tool, and turn-end coverage.
Run `bin/fm-test-run.sh tests/fm-copilot-harness.test.sh` for portable worker coverage.
Run the Copilot live guards named in `docs/verification/supervision.md` and `docs/verification/copilot.md` after Copilot CLI or SDK upgrades.
