#!/usr/bin/env bash
# fm-install-herdr-web.sh - install a pinned, verified herdr-web release.
#
# Single owner of the exact herdr-web version, release asset URLs, and SHA-256
# pins used by the devcontainer. Never installs a floating latest.
#
# Usage:
#   fm-install-herdr-web.sh <bin-directory> [<install-root>]
#
# herdr-web (https://github.com/kcosr/herdr-web) is an unofficial browser
# client for Herdr; its bridge needs a running Herdr v0.9.0 or newer session
# reporting terminal protocol 22, which bin/fm-install-herdr.sh provides.
# The release tarball is verified, unpacked under
# <install-root>/herdr-web-<tag> (default ~/.local/opt), and a small
# `herdr-web` launcher is written to <bin-directory>. The bundled wrapper
# resolves its web assets relative to its own path, so the launcher execs it
# by absolute path rather than symlinking it.
set -eu

# Exact pin - change only after checking herdr-web's required Herdr version.
FM_HERDR_WEB_VERSION=0.6.2
FM_HERDR_WEB_TAG="v${FM_HERDR_WEB_VERSION}"
# Bounded download ceiling (bytes). The largest 0.6.2 desktop tarball is under 6 MB.
FM_HERDR_WEB_MAX_BYTES=15000000
FM_HERDR_WEB_REPO=kcosr/herdr-web

die() {
  printf 'fm-install-herdr-web.sh: %s\n' "$*" >&2
  exit 1
}

BIN_DIR=${1:?usage: fm-install-herdr-web.sh <bin-directory> [<install-root>]}
INSTALL_ROOT=${2:-$HOME/.local/opt}

os=$(uname -s)
arch=$(uname -m)
case "${os}-${arch}" in
  Linux-x86_64)
    PLATFORM=linux-x86_64
    SHA256=76d04fcd8e68c88879671a3af53d862fedfb3f217962eba0c977ed7d3a916b24
    ;;
  Darwin-arm64)
    PLATFORM=macos-arm64
    SHA256=bb7284e9ecea3621bf0651adcf16c8ca063213b7a577a17847aace2044dbadb4
    ;;
  Darwin-x86_64)
    PLATFORM=macos-x86_64
    SHA256=1784a520d270bab69b96ee07cf6bb48012104d83aef4d9218481b2a5cde25e23
    ;;
  *)
    die "unsupported platform ${os}-${arch}; herdr-web ships linux x86_64 and macos arm64/x86_64 tarballs"
    ;;
esac

NAME="herdr-web-${FM_HERDR_WEB_TAG}-${PLATFORM}"
ASSET="${NAME}.tar.gz"
URL="https://github.com/${FM_HERDR_WEB_REPO}/releases/download/${FM_HERDR_WEB_TAG}/${ASSET}"
TMP=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/fm-herdr-web.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

printf 'fm-install-herdr-web.sh: downloading %s from %s\n' "$ASSET" "$URL" >&2
curl -fsSL --max-filesize "$FM_HERDR_WEB_MAX_BYTES" "$URL" -o "$TMP/$ASSET" \
  || die "download failed for $URL (bounded at $FM_HERDR_WEB_MAX_BYTES bytes)"

if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL_SHA256=$(sha256sum "$TMP/$ASSET" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
  ACTUAL_SHA256=$(shasum -a 256 "$TMP/$ASSET" | awk '{print $1}')
else
  die "need sha256sum or shasum to verify the herdr-web asset"
fi
[ "$ACTUAL_SHA256" = "$SHA256" ] || die "checksum mismatch for $ASSET (expected $SHA256, got $ACTUAL_SHA256)"

tar -xzf "$TMP/$ASSET" -C "$TMP"
[ -x "$TMP/$NAME/bin/herdr-web" ] && [ -x "$TMP/$NAME/bin/herdr-web-bridge" ] \
  || die "unexpected tarball layout: $NAME/bin/herdr-web or herdr-web-bridge missing"

mkdir -p "$INSTALL_ROOT" "$BIN_DIR"
TARGET="$INSTALL_ROOT/$NAME"
rm -rf "$TARGET"
mv "$TMP/$NAME" "$TARGET"

cat >"$BIN_DIR/herdr-web" <<EOF
#!/usr/bin/env bash
exec "$TARGET/bin/herdr-web" "\$@"
EOF
chmod 0755 "$BIN_DIR/herdr-web"

"$BIN_DIR/herdr-web" --help >/dev/null 2>&1 \
  || die "installed herdr-web launcher did not run"

printf 'fm-install-herdr-web.sh: installed herdr-web %s to %s (launcher %s)\n' \
  "$FM_HERDR_WEB_VERSION" "$TARGET" "$BIN_DIR/herdr-web" >&2
