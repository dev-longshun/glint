#!/usr/bin/env bash
# Generate (or reuse) a Sparkle EdDSA keypair for Glint and wire it up:
#   * write the public key into Glint/Resources/Info.plist as SUPublicEDKey
#   * export the private key and offer to upload it to the
#     SPARKLE_ED_PRIV_KEY GitHub secret on chenbstack/glint, so the release
#     workflow can sign update DMGs.
#
# The private key is stored in the macOS login Keychain by `generate_keys`
# and is also written to a 0600 temp file just long enough to push it as
# a secret. The temp file is removed before this script exits.
#
# Run from the repo root. Requires `gh` logged in to the repo's owner.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SPARKLE_VERSION="${SPARKLE_VERSION:-2.6.4}"
# Pinned sha256 of Sparkle-2.6.4.tar.xz. `generate_keys` handles the EdDSA
# private key, so never run a binary we haven't checksummed (same policy as
# scripts/setup-ghosttykit.sh). Overriding SPARKLE_VERSION requires also
# exporting SPARKLE_SHA256 for the new artifact.
if [ "$SPARKLE_VERSION" = "2.6.4" ]; then
  SPARKLE_SHA256="${SPARKLE_SHA256:-50612a06038abc931f16011d7903b8326a362c1074dabccb718404ce8e585f0b}"
elif [ -z "${SPARKLE_SHA256:-}" ]; then
  echo "ERROR: SPARKLE_VERSION=$SPARKLE_VERSION has no pinned sha256." >&2
  echo "Export SPARKLE_SHA256=<sha256 of Sparkle-${SPARKLE_VERSION}.tar.xz> to proceed." >&2
  exit 1
fi
SPARKLE_DIR="$ROOT/.sparkle"
GEN_KEYS="$SPARKLE_DIR/bin/generate_keys"
INFO_PLIST="Glint/Resources/Info.plist"
REPO="${SPARKLE_REPO:-chenbstack/glint}"
PRIV_TMP="$(mktemp -t sparkle-priv.XXXXXX)"
trap 'rm -f "$PRIV_TMP"' EXIT

# 1. Fetch Sparkle's tools if missing. Download to a temp file and verify
# the pinned sha256 before extracting — never stream untrusted bytes
# straight into tar.
if [ ! -x "$GEN_KEYS" ]; then
  echo "Downloading Sparkle ${SPARKLE_VERSION}..."
  SPARKLE_TARBALL="$(mktemp -t sparkle-dist.XXXXXX)"
  trap 'rm -f "$PRIV_TMP" "$SPARKLE_TARBALL"' EXIT
  curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz" \
    -o "$SPARKLE_TARBALL"
  ACTUAL_SHA256="$(shasum -a 256 "$SPARKLE_TARBALL" | awk '{print $1}')"
  if [ "$ACTUAL_SHA256" != "$SPARKLE_SHA256" ]; then
    cat >&2 <<EOF
ERROR: Sparkle ${SPARKLE_VERSION} sha256 mismatch.
  expected: $SPARKLE_SHA256
  actual:   $ACTUAL_SHA256
EOF
    exit 1
  fi
  mkdir -p "$SPARKLE_DIR"
  tar -xJf "$SPARKLE_TARBALL" -C "$SPARKLE_DIR" --strip-components=1
fi

# 2. Either reuse an existing keypair from the Keychain, or generate one.
if PUB="$("$GEN_KEYS" -p 2>/dev/null)" && [ -n "$PUB" ]; then
  echo "Reusing existing Sparkle keypair from Keychain."
else
  echo "No Sparkle keypair found — generating one. Keychain may prompt."
  "$GEN_KEYS"
  PUB="$("$GEN_KEYS" -p)"
fi
echo "Public key: $PUB"

# 3. Export the private key (Sparkle 2.6+: `generate_keys -x <path>`).
# Don't swallow output — generate_keys may print a Keychain access prompt
# notice, and the user needs to click "Always Allow" in the dialog that
# pops up. If you redirect to /dev/null the script looks like it succeeded
# while writing an empty file.
"$GEN_KEYS" -x "$PRIV_TMP"
chmod 0600 "$PRIV_TMP"
if [ ! -s "$PRIV_TMP" ]; then
  echo "ERROR: private key export produced an empty file." >&2
  exit 1
fi

# 4. Stamp the public key into Info.plist.
plutil -replace SUPublicEDKey -string "$PUB" "$INFO_PLIST"
echo "Wrote SUPublicEDKey into $INFO_PLIST."

# 5. Offer to push the private key to the repo's GitHub Secret.
if command -v gh >/dev/null 2>&1; then
  echo
  echo "Push private key to GitHub secret SPARKLE_ED_PRIV_KEY on $REPO?"
  printf "  [y/N] "
  read -r reply
  if [ "${reply:-N}" = "y" ] || [ "${reply:-N}" = "Y" ]; then
    gh secret set SPARKLE_ED_PRIV_KEY --repo "$REPO" < "$PRIV_TMP"
    echo "Uploaded SPARKLE_ED_PRIV_KEY."
  else
    echo "Skipped. To upload later:"
    echo "  gh secret set SPARKLE_ED_PRIV_KEY --repo $REPO < <(this script with --print-priv)"
  fi
else
  echo "gh CLI not on PATH — cannot push secret automatically."
  echo "Set it manually: chenbstack/glint → Settings → Secrets → SPARKLE_ED_PRIV_KEY"
fi

echo
echo "Done. Commit Info.plist next:"
echo "  git add $INFO_PLIST && git commit -m 'sparkle: wire public EdDSA key'"
