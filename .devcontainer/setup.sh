#!/usr/bin/env bash
# Package feeds come from FIRSTMATE_NPM_REGISTRY and FIRSTMATE_PIP_INDEX_URL,
# taken from the host environment (devcontainer.json forwards both) or else
# from this checkout's untracked .env, so no feed address lives in the
# repository. With neither set, npm and pip keep their public defaults; a
# network that blocks those must set both values before the container builds.
# Docker's default seccomp profile blocks Chromium's namespace sandbox, so
# devcontainer.json disables that sandbox only for browser automation.
# Herdr's Pi integration installs a global extension that Pi loads on startup.
# Docker delivers a published port to the container's own address, so every new
# shell binds Lavish there; Lavish refuses wildcard addresses, and the address
# changes per container, so it is derived at shell start rather than fixed.
# A Windows clone checks tracked symlinks out as plain files, so setup restores
# any still matching git's copy once the mount proves it can hold real links.
set -euo pipefail

# shellcheck source=bin/fm-env-lib.sh
. bin/fm-env-lib.sh
NPM_REGISTRY=${FIRSTMATE_NPM_REGISTRY:-$(fmx_env_get FIRSTMATE_NPM_REGISTRY .env)}
PIP_INDEX_URL=${FIRSTMATE_PIP_INDEX_URL:-$(fmx_env_get FIRSTMATE_PIP_INDEX_URL .env)}

mkdir -p "$HOME/.local/bin"
sudo chown -R "$(id -un):$(id -gn)" "$HOME/.config" "$HOME/.copilot" "$HOME/.local"
export PATH="$HOME/.local/bin:$PATH"

sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  tmux jq python3 python3-pip chromium fonts-liberation

# chrome-devtools-mcp finds the stable channel only at Google's install path.
sudo mkdir -p /opt/google/chrome
sudo ln -sfn /usr/bin/chromium /opt/google/chrome/chrome

bash bin/fm-install-shellcheck.sh "$HOME/.local/bin"
bash bin/fm-install-actionlint.sh "$HOME/.local/bin"
bash bin/fm-install-herdr.sh "$HOME/.local/bin"

if [ -n "$NPM_REGISTRY" ]; then
  npm config set registry "$NPM_REGISTRY"
fi
if [ -n "$PIP_INDEX_URL" ]; then
  mkdir -p "$HOME/.config/pip"
  printf '[global]\nindex-url = %s\n' "$PIP_INDEX_URL" > "$HOME/.config/pip/pip.conf"
fi

if ! git config --system --get-all safe.directory 2>/dev/null | grep -Fxq '*'; then
  sudo git config --system --add safe.directory '*'
fi

repair_tracked_links() {
  local git_dir probe entry mode blob path
  git_dir=$(git rev-parse --git-dir) || return 0
  probe="$git_dir/fm-symlink-probe.$$"
  rm -f "$probe"
  if ! ln -s fm-symlink-probe-target "$probe" 2>/dev/null || [ ! -L "$probe" ]; then
    rm -f "$probe"
    echo "setup: warning: this filesystem cannot hold symlinks; tracked links left as checked out" >&2
    return 0
  fi
  rm -f "$probe"
  if ! git config core.symlinks true; then
    echo "setup: warning: could not set core.symlinks; tracked links left as checked out" >&2
    return 0
  fi
  while IFS= read -r -d '' entry; do
    path=${entry#*$'\t'}
    read -r mode blob _ <<<"${entry%%$'\t'*}"
    [ "$mode" = 120000 ] || continue
    [ -L "$path" ] && continue
    if [ -f "$path" ] && [ "$(git hash-object -- "$path" 2>/dev/null)" = "$blob" ]; then
      git checkout -- "$path" \
        || echo "setup: warning: could not restore tracked link $path" >&2
    else
      echo "setup: warning: $path differs from its tracked link; left untouched" >&2
    fi
  done < <(git ls-files -s -z)
}
repair_tracked_links

npm install -g @github/copilot chrome-devtools-mcp @earendil-works/pi-coding-agent

bash bin/fm-bootstrap.sh install \
  treehouse \
  no-mistakes \
  gh-axi \
  chrome-devtools-axi \
  tasks-axi \
  quota-axi \
  lavish-axi

bash bin/fm-copilot-hook-install.sh

# fm-bootstrap.sh install continues after a failed installer, so verify the result.
report=$(FM_BOOTSTRAP_DETECT_ONLY=1 FM_BOOTSTRAP_NETWORK=skip bash bin/fm-bootstrap.sh)
missing=$(printf '%s\n' "$report" \
  | grep -E '^(MISSING|MISSING_MANUAL|PRESENTATION_UNAVAILABLE|BACKEND_INVALID):' || true)
if [ -n "$missing" ]; then
  printf '%s\n' "$missing" >&2
  exit 1
fi
for tool in shellcheck actionlint herdr chrome-devtools-mcp copilot pi; do
  command -v "$tool" >/dev/null || { echo "setup: $tool is missing" >&2; exit 1; }
done
pi --version
mkdir -p "$HOME/.pi/agent/extensions"
herdr integration install pi

browser_dom=$(timeout 60 chromium --headless --no-sandbox --disable-gpu \
  --dump-dom 'data:text/html,<p>firstmate-browser-ready</p>' 2>/dev/null)
case "$browser_dom" in
  *firstmate-browser-ready*) ;;
  *) echo "setup: Chromium could not render a page" >&2; exit 1 ;;
esac

lavish_marker='# firstmate: bind Lavish to the container address'
for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
  [ "$rc" = "$HOME/.bashrc" ] || [ -f "$rc" ] || continue
  grep -Fq "$lavish_marker" "$rc" 2>/dev/null && continue
  cat >> "$rc" <<'RC'

# firstmate: bind Lavish to the container address
lavish_ip=$(hostname -i 2>/dev/null | awk '{print $1}')
[ -z "$lavish_ip" ] || export LAVISH_AXI_HOST="$lavish_ip"
unset lavish_ip
RC
done
