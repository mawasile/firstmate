#!/usr/bin/env bash
# Package feeds come from FIRSTMATE_NPM_REGISTRY and FIRSTMATE_PIP_INDEX_URL,
# taken from the host environment (devcontainer.json forwards both) or else
# from this checkout's untracked .env, so no feed address lives in the
# repository. With neither set, npm and pip keep their public defaults; a
# network that blocks those must set both values before the container builds.
# Docker's default seccomp profile blocks Chromium's namespace sandbox, so
# devcontainer.json disables that sandbox only for browser automation.
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

npm install -g @github/copilot chrome-devtools-mcp

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
for tool in shellcheck actionlint herdr chrome-devtools-mcp copilot; do
  command -v "$tool" >/dev/null || { echo "setup: $tool is missing" >&2; exit 1; }
done
browser_dom=$(timeout 60 chromium --headless --no-sandbox --disable-gpu \
  --dump-dom 'data:text/html,<p>firstmate-browser-ready</p>' 2>/dev/null)
case "$browser_dom" in
  *firstmate-browser-ready*) ;;
  *) echo "setup: Chromium could not render a page" >&2; exit 1 ;;
esac