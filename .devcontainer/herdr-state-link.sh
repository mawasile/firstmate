#!/usr/bin/env bash
# herdr-state-link.sh - keep Herdr's state in this checkout's .herdr/ folder.
#
# Usage:
#   herdr-state-link.sh
#
# Herdr keeps its config, workspace layout (session.json, which links each pane
# to its agent session), sockets, and logs under ~/.config/herdr. Only
# HERDR_CONFIG_PATH is configurable, and it moves config.toml alone, so this
# replaces ~/.config/herdr with a link to <checkout>/.herdr, the same way
# PI_CODING_AGENT_DIR keeps Pi sessions in .pi-agent/. The checkout survives a
# rebuild, so Herdr can resume each pane's agent afterwards.
#
# Idempotent: an existing correct link is left alone. A real ~/.config/herdr
# directory is migrated (sockets skipped, existing .herdr files kept) only
# while no Herdr server is running, because moving a live server's sockets
# would cut every client off; otherwise it reports and leaves things as they
# are for the next shell start.
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TARGET=$ROOT/.herdr
LINK=${XDG_CONFIG_HOME:-$HOME/.config}/herdr

mkdir -p "$TARGET" "$(dirname "$LINK")"

if [ -L "$LINK" ]; then
  [ "$(readlink "$LINK")" = "$TARGET" ] && exit 0
  rm -f "$LINK"
elif [ -d "$LINK" ]; then
  if pgrep -u "$(id -u)" -f '(^|/)herdr server( |$)' >/dev/null 2>&1; then
    echo "herdr-state-link: Herdr is running from $LINK; will move its state to $TARGET at the next start" >&2
    exit 0
  fi
  # Copy everything (tar skips sockets), never overwriting what .herdr has.
  (cd "$LINK" && tar -cf - . 2>/dev/null) | (cd "$TARGET" && tar -xkf - 2>/dev/null)
  find "$TARGET" -type s -delete 2>/dev/null
  missing=$(cd "$LINK" && find . -type f -print | while IFS= read -r f; do
    [ -e "$TARGET/$f" ] || printf '%s\n' "$f"; done)
  if [ -n "$missing" ]; then
    printf 'herdr-state-link: copy to %s incomplete; %s left in place. Missing:\n%s\n' \
      "$TARGET" "$LINK" "$missing" >&2
    exit 1
  fi
  rm -rf "$LINK"
elif [ -e "$LINK" ]; then
  echo "herdr-state-link: $LINK exists and is not a directory or link; left untouched" >&2
  exit 1
fi

ln -s "$TARGET" "$LINK"
