Mode: GitHub Copilot foreground checkpoint.

When this session owns supervision and away mode is not active, supervise with an in-turn checkpoint loop:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. Run one foreground checkpoint with `bin/fm-watch-checkpoint.sh --seconds ${FM_COPILOT_WATCH_CHECKPOINT:-180}`.
   Use a synchronous bash call whose `initial_wait` exceeds that bound by at least 30 seconds, so the tool returns the checkpoint's own result instead of moving it to the background.
3. Keep that tool call in the foreground.
   Do not use shell `&`, async mode, a pipeline, command substitution, a wrapper, or an unrelated command list.
   The PreToolUse hook denies the shell forms before execution.
4. Ordinary wake: if the checkpoint prints `signal:`, `stale:`, `check:`, or `heartbeat`, drain, handle the wake, run the printed acknowledgement, then start the next checkpoint in the same turn.
5. If the checkpoint prints `checkpoint:` or exits 124 with no wake, drain anyway, run any printed acknowledgement, then start the next checkpoint in the same turn.
   A quiet bound is the loop's normal rhythm, not a supervision failure.
   If the checkpoint fails any other way, such as a killed exit, drain, inspect the failure, then start a fresh checkpoint in the same turn.
6. Do not end the turn while supervision is still needed.
   Send captain-facing outcomes as messages between checkpoints; they reach the captain at once, so a wake that needs the captain is reported without leaving the loop.
7. A captain message may arrive while a checkpoint runs and move that checkpoint to the background.
   Handle the message, then wait for that checkpoint's completion notification, or read its shell, before starting another; a second checkpoint while one still runs is refused.
8. The native `agentStop` hook is only a backstop: when a turn ends anyway while supervision is still needed, its one bounded continuation resumes this loop.
9. Never run `bin/fm-watch.sh` directly.

The scoped Copilot hook installed by `bin/fm-copilot-hook-install.sh` owns session start, pre-tool protection, the bounded turn-end continuation, and session cleanup.
The per-session guardian keeps logical Copilot chats distinct even when the VS Code SDK shares one `copilot-runtime` process.
