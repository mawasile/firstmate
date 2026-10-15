#!/usr/bin/env bash
# Shared GitHub Copilot CLI and SDK primary identity.
#
# The VS Code SDK host keeps one copilot-runtime process across logical chat
# sessions, so that process is harness evidence but is never a safe session-lock
# anchor. The tracked session-start hook creates a guardian whose process title
# is fm-copilot-ses and passes its pid when it runs session-start. That
# per-session process is the lock anchor and exits with the logical session.
#
# Ordinary tool subprocesses do not descend from the guardian. They prove the
# same logical session with COPILOT_AGENT_SESSION_ID plus the SDK runtime's
# session-specific inuse record. The recorded guardian pid must still be live.

FM_COPILOT_PROCESS_KIND=

fm_copilot_process_matches() {  # <comm> [<args>]
  local base argv0
  base=$(basename -- "$1")
  FM_COPILOT_PROCESS_KIND=
  case "$base" in
    copilot|copilot-runtime)
      FM_COPILOT_PROCESS_KIND=runtime
      return 0
      ;;
    fm-copilot-ses)
      FM_COPILOT_PROCESS_KIND=session
      return 0
      ;;
    MainThread)
      # Modern Node on Linux reports the native binary's comm as MainThread, so
      # the executable name only survives in argv[0].
      argv0=${2%% *}
      if [ "$(basename -- "$argv0")" = copilot ]; then
        FM_COPILOT_PROCESS_KIND=runtime
        return 0
      fi
      ;;
  esac
  return 1
}

fm_copilot_session_id_valid() {  # <id>
  case "${1:-}" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

fm_copilot_session_pid_alive() {  # <pid>
  local wanted=$1 comm
  case "$wanted" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$wanted" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$wanted" 2>/dev/null) || return 1
  fm_copilot_process_matches "$comm" || return 1
  [ "$FM_COPILOT_PROCESS_KIND" = session ]
}

fm_copilot_session_active() {  # <runtime-pid> <session-id>
  local runtime_pid=$1 session_id=$2 home session_dir lock hold recorded
  case "$runtime_pid" in ''|*[!0-9]*) return 1 ;; esac
  fm_copilot_session_id_valid "$session_id" || return 1
  home=${COPILOT_HOME:-${HOME:-}/.copilot}
  case "$home" in /*) ;; *) return 1 ;; esac
  session_dir="$home/session-state/$session_id"
  lock="$session_dir/inuse.$runtime_pid.lock"
  hold="$session_dir/inuse.$runtime_pid.hold"
  [ -f "$lock" ] && [ ! -L "$lock" ] || return 1
  [ -f "$hold" ] && [ ! -L "$hold" ] || return 1
  recorded=$(head -n 1 "$lock" 2>/dev/null) || return 1
  [ "$recorded" = "$runtime_pid" ]
}
