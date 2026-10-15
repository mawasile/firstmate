Mode: GitHub Copilot foreground checkpoint.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. Start or continue the foreground checkpoint with `bin/fm-watch-checkpoint.sh --seconds ${FM_COPILOT_WATCH_CHECKPOINT:-180}`.
3. Keep that tool call in the foreground.
   Do not use shell `&`, a pipeline, command substitution, a wrapper, or an unrelated command list.
   The PreToolUse hook denies those unsafe forms before execution.
4. If the checkpoint prints an actionable wake, handle it, drain and acknowledge the durable queue, then end the turn.
5. If the checkpoint reports no actionable wake within its bound, drain once and end the turn.
   The native `agentStop` hook starts one bounded continuation when supervision is still needed, and that continuation runs the next checkpoint.
6. A captain message may interrupt the foreground checkpoint.
   Handle the message, then let the `agentStop` hook restore the next checkpoint when supervision remains necessary.
7. Never run `bin/fm-watch.sh` directly.

The scoped Copilot hook installed by `bin/fm-copilot-hook-install.sh` owns session start, pre-tool protection, the bounded turn-end continuation, and session cleanup.
The per-session guardian keeps logical Copilot chats distinct even when the VS Code SDK shares one `copilot-runtime` process.
