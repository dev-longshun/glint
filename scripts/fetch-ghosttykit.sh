#!/usr/bin/env bash
# Fetch the prebuilt GhosttyKit.xcframework into Vendor/.
#
# The xcframework is ~500MB so it's not committed to the repo. CI and fresh
# clones must download it from an HTTP location. Set GHOSTTYKIT_URL to a
# .tar.gz / .tar.xz / .zip containing GhosttyKit.xcframework at its root.
#
# Recommended: host the bundle as a GitHub Release asset on your own fork
# of ghostty, and put the public URL in the repo secret GHOSTTYKIT_URL.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor"
TARGET="$VENDOR/GhosttyKit.xcframework"

if [ -d "$TARGET" ] && [ -f "$TARGET/Info.plist" ]; then
  echo "GhosttyKit.xcframework already present — skipping fetch."
  exit 0
fi

if [ -z "${GHOSTTYKIT_URL:-}" ]; then
  cat >&2 <<EOF
ERROR: GhosttyKit.xcframework is missing and GHOSTTYKIT_URL is not set.

Set the env var (or repo secret) GHOSTTYKIT_URL to a public URL that
serves the framework as a tar.gz / tar.xz / zip archive.

Example (locally):
  GHOSTTYKIT_URL='https://github.com/you/ghostty-kit/releases/download/v1.2.3/GhosttyKit.xcframework.tar.gz' \\
    bash scripts/fetch-ghosttykit.sh
EOF
  exit 1
fi

mkdir -p "$VENDOR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ARCHIVE="$TMP/ghosttykit.archive"
echo "Fetching GhosttyKit from $GHOSTTYKIT_URL"
curl -fL --retry 3 --retry-delay 5 -o "$ARCHIVE" "$GHOSTTYKIT_URL"

case "$GHOSTTYKIT_URL" in
  *.tar.gz|*.tgz) tar -xzf "$ARCHIVE" -C "$TMP" ;;
  *.tar.xz)       tar -xJf "$ARCHIVE" -C "$TMP" ;;
  *.zip)          unzip -q "$ARCHIVE" -d "$TMP" ;;
  *) echo "ERROR: unsupported archive extension in $GHOSTTYKIT_URL" >&2; exit 1 ;;
esac

# Find the xcframework anywhere in the extracted tree.
EXTRACTED="$(find "$TMP" -maxdepth 4 -type d -name 'GhosttyKit.xcframework' | head -n1)"
if [ -z "$EXTRACTED" ]; then
  echo "ERROR: archive did not contain GhosttyKit.xcframework/" >&2
  exit 1
fi

rm -rf "$TARGET"
mv "$EXTRACTED" "$TARGET"
echo "GhosttyKit.xcframework installed at $TARGET"
