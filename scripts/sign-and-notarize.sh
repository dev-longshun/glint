#!/usr/bin/env bash
# Codesign a built .app with a Developer ID cert, then notarize + staple.
#
# Required env (set as GitHub secrets in the release workflow):
#   APPLE_CERT_P12_BASE64   base64 of the Developer ID Application .p12
#   APPLE_CERT_PASSWORD     password used when exporting the .p12
#   APPLE_NOTARY_ID         apple id used for notarytool
#   APPLE_NOTARY_PASSWORD   app-specific password
#   APPLE_NOTARY_TEAM_ID    your developer team id
#   BUNDLE_ID               app bundle id (defaults to app.glint.Glint)
#
# Usage:  scripts/sign-and-notarize.sh path/to/Glint.app

set -euo pipefail

APP="${1:?usage: sign-and-notarize.sh <App.app>}"
: "${APPLE_CERT_P12_BASE64:?missing}"
: "${APPLE_CERT_PASSWORD:?missing}"
: "${APPLE_NOTARY_ID:?missing}"
: "${APPLE_NOTARY_PASSWORD:?missing}"
: "${APPLE_NOTARY_TEAM_ID:?missing}"
BUNDLE_ID="${BUNDLE_ID:-app.glint.Glint}"

KEYCHAIN="$RUNNER_TEMP/glint-build.keychain-db"
KEYCHAIN_PASSWORD="$(uuidgen)"

umask 077
CERT_PATH="$RUNNER_TEMP/cert.p12"
printf '%s' "$APPLE_CERT_P12_BASE64" | base64 --decode > "$CERT_PATH"

# Throwaway keychain — torn down on every run.
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$CERT_PATH" -k "$KEYCHAIN" -P "$APPLE_CERT_PASSWORD" \
  -T /usr/bin/codesign -T /usr/bin/security
security list-keychains -d user -s "$KEYCHAIN" "$(security list-keychains -d user | tr -d '\"' | xargs)"
security set-key-partition-list -S apple-tool:,apple:,codesign: \
  -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null

IDENTITY="$(security find-identity -v -p codesigning "$KEYCHAIN" | \
  grep -oE '"Developer ID Application: [^"]+"' | head -n1 | tr -d '"')"
if [ -z "$IDENTITY" ]; then
  echo "ERROR: no Developer ID Application identity in imported cert." >&2
  exit 1
fi
echo "Signing with: $IDENTITY"

# Sign frameworks bottom-up, then the app itself.
find "$APP/Contents/Frameworks" -type d -name '*.framework' -depth 2>/dev/null | while read -r fw; do
  /usr/bin/codesign --force --options runtime --timestamp \
    --sign "$IDENTITY" "$fw"
done
/usr/bin/codesign --force --options runtime --timestamp --deep \
  --sign "$IDENTITY" "$APP"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"

# Notarize. notarytool waits for Apple to come back (~1-5 min).
ZIP="$RUNNER_TEMP/glint-notarize.zip"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" \
  --apple-id "$APPLE_NOTARY_ID" \
  --password "$APPLE_NOTARY_PASSWORD" \
  --team-id "$APPLE_NOTARY_TEAM_ID" \
  --wait

xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

# Tear down the keychain.
security delete-keychain "$KEYCHAIN" || true
rm -f "$CERT_PATH" "$ZIP"

echo "Signed + notarized + stapled: $APP"
