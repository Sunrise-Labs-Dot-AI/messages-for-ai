#!/usr/bin/env bash
#
# Build, sign, notarize, and staple the polished drag-to-install .dmg
# for a Messages for AI release.
#
# Runs AFTER scripts/build-release.sh has produced the notarized .zip
# in dist/. Extracts the .app from that zip, wraps it in a create-dmg
# layout (drag-to-Applications), signs + notarizes + staples the .dmg,
# and outputs dist/Messages-for-AI.dmg.
#
# The output filename is stable (no version suffix) so the marketing
# site's /releases/latest/download/Messages-for-AI.dmg URL works
# without touching site/index.html on every release.
#
# Usage:
#   bash scripts/build-dmg.sh <version>   # e.g. v0.3.2.1
#
# Required environment / state:
#   - scripts/build-release.sh has already run for the same VERSION;
#     dist/messages-for-ai-<version>.zip exists.
#   - create-dmg is installed (brew install create-dmg) — script will
#     auto-install if missing.
#   - Developer ID Application cert in keychain (auto-detected by
#     filter on Team ID).
#   - Notarytool keychain profile (override via NOTARY_PROFILE env var).

set -euo pipefail

VERSION="${1:?usage: build-dmg.sh <version>, e.g. v0.3.2.1}"
NOTARY_PROFILE="${NOTARY_PROFILE:-imessage-drafts-mcp-notary}"
EXPECTED_TEAM_ID="${EXPECTED_TEAM_ID:-LQ93LRM9QU}"

SECURITY=/usr/bin/security
CODESIGN=/usr/bin/codesign
AWK=/usr/bin/awk

cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"
DIST="$REPO_ROOT/dist"
RELEASE_NAME="messages-for-ai-$VERSION"
RELEASE_ZIP="$DIST/$RELEASE_NAME.zip"
STAGE="$DIST/dmg-stage"
DMG="$DIST/Messages-for-AI.dmg"

if [[ ! -f "$RELEASE_ZIP" ]]; then
  echo "✗ release zip not found: $RELEASE_ZIP" >&2
  echo "  Run scripts/build-release.sh $VERSION first." >&2
  exit 1
fi

SIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY=$("$SECURITY" find-identity -v -p codesigning 2>/dev/null \
    | "$AWK" -F\" -v team="$EXPECTED_TEAM_ID" \
        '/Developer ID Application/ && $2 ~ "\\("team"\\)$" {print $2; exit}')
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
  echo "✗ no 'Developer ID Application' cert from team $EXPECTED_TEAM_ID found." >&2
  exit 1
fi
echo "› signing identity: $SIGN_IDENTITY"

if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "✗ notarytool credentials not found under profile '$NOTARY_PROFILE'." >&2
  exit 1
fi
echo "› notarytool profile: $NOTARY_PROFILE"

if ! command -v create-dmg >/dev/null; then
  echo "› installing create-dmg via brew"
  brew install create-dmg
fi

echo
echo "=== Extracting notarized .app from $RELEASE_ZIP ==="
rm -rf "$STAGE"
mkdir -p "$STAGE"
TMP_UNZIP=$(mktemp -d)
unzip -q "$RELEASE_ZIP" "$RELEASE_NAME/Messages for AI.app/*" -d "$TMP_UNZIP"
mv "$TMP_UNZIP/$RELEASE_NAME/Messages for AI.app" "$STAGE/"
rm -rf "$TMP_UNZIP"
xcrun stapler validate "$STAGE/Messages for AI.app" >/dev/null
echo "  ✓ stapled ticket survived the extract"

echo
echo "=== Building polished .dmg (create-dmg) ==="
rm -f "$DMG"
# Window + icon coordinates picked to look right on a 640x380 default-
# size DMG window. Background image is a v0.3.3+ polish item — needs a
# designed PNG with a drag-arrow visual. Layout is correct without it.
create-dmg \
  --volname "Messages for AI" \
  --window-pos 200 120 \
  --window-size 640 380 \
  --icon-size 100 \
  --icon "Messages for AI.app" 160 180 \
  --hide-extension "Messages for AI.app" \
  --app-drop-link 480 180 \
  --no-internet-enable \
  "$DMG" \
  "$STAGE"

echo
echo "=== Signing .dmg ==="
"$CODESIGN" --sign "$SIGN_IDENTITY" --options runtime --timestamp "$DMG"

echo
echo "=== Notarizing .dmg (Apple round-trip, ~2-3 min) ==="
NOTARIZE_DMG_JSON="$DIST/notarize-dmg.json"
xcrun notarytool submit "$DMG" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait \
  --output-format json > "$NOTARIZE_DMG_JSON"

DMG_STATUS=$(/usr/bin/python3 -c "import json; print(json.load(open('$NOTARIZE_DMG_JSON'))['status'])")
if [[ "$DMG_STATUS" != "Accepted" ]]; then
  echo "✗ DMG notarization failed: $DMG_STATUS" >&2
  cat "$NOTARIZE_DMG_JSON" >&2
  exit 1
fi

echo
echo "=== Stapling notarization ticket ==="
xcrun stapler staple "$DMG"
spctl -a -vv -t open --context context:primary-signature "$DMG" 2>&1 | head -3

# Cleanup the stage dir; leave the .dmg + notarize JSON for audit.
rm -rf "$STAGE"

echo
echo "✓ polished .dmg built: $DMG"
echo
echo "Next steps:"
echo "  1. Upload to the GitHub release:"
echo "       gh release upload $VERSION $DMG"
echo "  2. The marketing site at messagesfor.ai pulls from"
echo "       /releases/latest/download/Messages-for-AI.dmg"
echo "     so as long as this asset is attached to the latest release,"
echo "     the Download button stays current."
