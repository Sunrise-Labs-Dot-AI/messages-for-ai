#!/usr/bin/env bash
#
# Build, sign, and notarize a release of imessage-mcp + the menu bar
# app, ready for upload to GitHub Releases.
#
# Output: dist/imessage-mcp-<version>.zip — a self-contained archive
# containing:
#   - bin/imessage-mcp            (signed + notarized command-line binary)
#   - iMessage Drafts.app/        (signed + notarized + stapled .app bundle)
#   - install.sh                  (end-user install script that copies the
#                                  above into ~/bin/ and /Applications/)
#   - README.md                   (short user-facing readme; full one is in repo)
#
# End users download the zip, extract, and run `bash install.sh`. No
# Xcode, no Developer Account, no rebuild required — Apple's
# notarization handles trust verification at first launch.
#
# Usage:
#   bash scripts/build-release.sh v0.1.0
#
# Required environment:
#   - Developer ID Application cert in keychain (auto-detected)
#   - Notarytool credentials stored in keychain as profile
#     "imessage-mcp-notary" (override via NOTARY_PROFILE env var).
#     One-time setup:
#       xcrun notarytool store-credentials imessage-mcp-notary \
#         --apple-id <your-apple-id-email> \
#         --team-id <your-team-id> \
#         --password <app-specific-password-from-appleid.apple.com>
#
# Resuming after an Apple notary backlog timeout:
#   Submission UUIDs are written to $DIST/notarize-mcp.uuid and
#   $DIST/notarize-app.uuid BEFORE we poll Apple. If `xcrun notarytool
#   wait` times out, you can re-poll without re-uploading (which would
#   burn another ~5-15 minutes) via:
#     xcrun notarytool wait $(cat dist/notarize-mcp.uuid) \
#       --keychain-profile imessage-mcp-notary
#   The trap on INT/TERM/EXIT wipes dist/ on abort, so you must save
#   the UUID elsewhere FIRST if you Ctrl-C during the wait. A future
#   refactor (deferred WARNING #14) will add a proper --resume flag.

set -euo pipefail

VERSION="${1:?usage: build-release.sh <version>, e.g. v0.1.1}"
NOTARY_PROFILE="${NOTARY_PROFILE:-imessage-mcp-notary}"

# The only Apple Developer Team ID this build accepts. Auto-detected
# certs from a different Team ID will be REJECTED rather than silently
# used — defends against an attacker who plants a Developer ID cert in
# the maintainer's keychain (via malicious npm postinstall, p12 import,
# stolen cert, etc.) and tries to ship attacker-signed releases.
EXPECTED_TEAM_ID="${EXPECTED_TEAM_ID:-LQ93LRM9QU}"

# Absolute paths to macOS-system binaries. Defends against PATH-shimmed
# `security` / `codesign` from a compromised dev environment.
SECURITY=/usr/bin/security
CODESIGN=/usr/bin/codesign
AWK=/usr/bin/awk

cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"
DIST="$REPO_ROOT/dist"
STAGE="$DIST/stage"
RELEASE_NAME="imessage-mcp-$VERSION"

# Find the Developer ID cert. Filters by EXPECTED_TEAM_ID to refuse
# attacker-planted certs in the same keychain. Fails loudly if no
# matching cert exists — notarized releases REQUIRE Developer ID
# signing; adhoc isn't valid.
SIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY=$("$SECURITY" find-identity -v -p codesigning 2>/dev/null \
    | "$AWK" -F\" -v team="$EXPECTED_TEAM_ID" \
        '/Developer ID Application/ && $2 ~ "\\("team"\\)$" {print $2; exit}')
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
  echo "✗ no 'Developer ID Application' cert from team $EXPECTED_TEAM_ID found." >&2
  echo "  Install one via Xcode → Settings → Accounts → Manage Certificates," >&2
  echo "  or set CODESIGN_IDENTITY=<identity-name> in the environment (bypasses" >&2
  echo "  the team-id filter — caller's responsibility to ensure it's the right cert)." >&2
  exit 1
fi
# Belt-and-suspenders: re-parse the chosen identity's Team ID and
# verify. This catches the CODESIGN_IDENTITY override case.
DETECTED_TEAM=$(echo "$SIGN_IDENTITY" | sed -nE 's/.*\(([A-Z0-9]+)\)$/\1/p')
if [[ "$DETECTED_TEAM" != "$EXPECTED_TEAM_ID" ]]; then
  echo "✗ signing identity Team ID '$DETECTED_TEAM' ≠ expected '$EXPECTED_TEAM_ID'" >&2
  exit 1
fi
# Print fingerprint so a maintainer auditing build logs can confirm
# which cert in the keychain was selected.
SIGN_HASH=$("$SECURITY" find-identity -v -p codesigning 2>/dev/null \
  | "$AWK" -v ident="$SIGN_IDENTITY" '$0 ~ ident {print $2; exit}')
echo "› signing identity: $SIGN_IDENTITY"
echo "› identity SHA-1:   $SIGN_HASH"

# Sanity-check that the notarytool credential profile exists before
# spending several minutes on a build that can't be notarized.
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "✗ notarytool credentials not found under profile '$NOTARY_PROFILE'." >&2
  echo "  Set up with:" >&2
  echo "    xcrun notarytool store-credentials $NOTARY_PROFILE \\" >&2
  echo "      --apple-id <your-apple-id> \\" >&2
  echo "      --team-id <your-team-id> \\" >&2
  echo "      --password <app-specific-password>" >&2
  exit 1
fi
echo "› notarytool profile: $NOTARY_PROFILE"

rm -rf "$DIST"
mkdir -p "$STAGE/$RELEASE_NAME/bin"

# Abort guard: if anything between here and the final success echo
# exits non-zero (or the user Ctrl-Cs), wipe dist/ so we never leave
# a signed-but-not-notarized binary that looks like a valid release.
# The trap is cleared right before the final success echoes.
trap 'rc=$?; echo; echo "✗ build aborted (exit $rc); wiping $DIST/" >&2; rm -rf "$DIST"' INT TERM EXIT

# ============================================================================
# 1. imessage-mcp binary
# ============================================================================
echo
echo "=== imessage-mcp binary ==="

echo "› bun build --compile"
bun build src/index.ts --compile --outfile "bin/imessage-mcp"
xattr -cr bin/imessage-mcp

echo "› signing with Developer ID + Hardened Runtime"
# Identifier `com.sunriselabs.imessage-mcp` (distinct from the dev
# identifier `com.local.imessage-mcp.dev` used by scripts/dev-install.sh).
# Different identifiers prevent a dev rebuild from clobbering the TCC
# grant established when a release binary is installed.
"$CODESIGN" --force --timestamp --sign "$SIGN_IDENTITY" \
  --identifier "com.sunriselabs.imessage-mcp" \
  --options=runtime \
  bin/imessage-mcp

echo "› notarizing imessage-mcp"
# Apple's notary service accepts zips for binary submission. We zip,
# submit, wait for approval, then extract the signed binary back out.
# (Binaries can't be stapled — the notarization is verified at
# runtime via a cloud lookup against Apple's CDN.)
#
# Two-step submit-then-wait so we can stash the submission UUID
# BEFORE the wait blocks. If Apple's notary backlog times us out,
# a maintainer can resume polling against the saved UUID instead
# of paying another upload round-trip — see script header.
NOTARIZE_DIR="$DIST/notarize-mcp"
mkdir -p "$NOTARIZE_DIR"
cp bin/imessage-mcp "$NOTARIZE_DIR/"
ditto -c -k --keepParent "$NOTARIZE_DIR/imessage-mcp" "$NOTARIZE_DIR/imessage-mcp.zip"
MCP_SUBMIT_JSON=$(xcrun notarytool submit "$NOTARIZE_DIR/imessage-mcp.zip" \
  --keychain-profile "$NOTARY_PROFILE" \
  --output-format json \
  --no-wait)
MCP_UUID=$(echo "$MCP_SUBMIT_JSON" | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin).get("id",""))')
if [[ -z "$MCP_UUID" ]]; then
  echo "✗ failed to parse mcp notarytool submission UUID from:" >&2
  echo "$MCP_SUBMIT_JSON" >&2
  exit 1
fi
echo "$MCP_UUID" > "$DIST/notarize-mcp.uuid"
echo "› mcp submission uuid: $MCP_UUID (resumable via: xcrun notarytool wait $MCP_UUID --keychain-profile $NOTARY_PROFILE)"
xcrun notarytool wait "$MCP_UUID" --keychain-profile "$NOTARY_PROFILE"

# The binary is unchanged by notarization — we just need to verify
# Apple stamped it. The codesign --verify --deep --strict already
# proves the signature is valid; the cloud check happens at runtime.
"$CODESIGN" --verify --strict --verbose=2 bin/imessage-mcp

cp bin/imessage-mcp "$STAGE/$RELEASE_NAME/bin/imessage-mcp"

# ============================================================================
# 2. iMessage Drafts.app menu bar bundle
# ============================================================================
echo
echo "=== iMessage Drafts.app ==="

cd "$REPO_ROOT/menubar"

echo "› swift build -c release"
swift build -c release

APP_NAME="iMessage Drafts"
BUNDLE_ID="com.sunriselabs.imessage-drafts"
EXE_NAME="iMessageDraftsMenu"
APP_PATH="$DIST/stage/$RELEASE_NAME/$APP_NAME.app"
ENTITLEMENTS="$REPO_ROOT/menubar/scripts/imessage-drafts.entitlements"

BIN=".build/release/$EXE_NAME"
if [[ ! -x "$BIN" ]]; then
  echo "expected $BIN to exist after swift build" >&2
  exit 1
fi

echo "› assembling $APP_NAME.app"
mkdir -p "$APP_PATH/Contents/MacOS"
mkdir -p "$APP_PATH/Contents/Resources"
cp "$BIN" "$APP_PATH/Contents/MacOS/$EXE_NAME"
xattr -cr "$APP_PATH"

cat > "$APP_PATH/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$EXE_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION#v}</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>iMessage Drafts sends staged iMessage drafts via Messages.app.</string>
  <key>NSContactsUsageDescription</key>
  <string>iMessage Drafts reads your Contacts to resolve recipient names. The same data Messages.app shows, including iCloud-synced contacts. The exported list is written only to ~/.imessage-mcp/contacts-cache.json on this Mac and never leaves the machine.</string>
  <key>NSHumanReadableCopyright</key>
  <string>Local-only utility. No data leaves this Mac.</string>
</dict>
</plist>
EOF

echo "› signing app with Developer ID + Hardened Runtime + entitlements"
"$CODESIGN" --force --deep --timestamp \
  --sign "$SIGN_IDENTITY" \
  --identifier "$BUNDLE_ID" \
  --options=runtime \
  --entitlements "$ENTITLEMENTS" \
  "$APP_PATH"

echo "› notarizing app"
NOTARIZE_APP_ZIP="$DIST/notarize-app.zip"
ditto -c -k --keepParent "$APP_PATH" "$NOTARIZE_APP_ZIP"
APP_SUBMIT_JSON=$(xcrun notarytool submit "$NOTARIZE_APP_ZIP" \
  --keychain-profile "$NOTARY_PROFILE" \
  --output-format json \
  --no-wait)
APP_UUID=$(echo "$APP_SUBMIT_JSON" | /usr/bin/python3 -c 'import json,sys;print(json.load(sys.stdin).get("id",""))')
if [[ -z "$APP_UUID" ]]; then
  echo "✗ failed to parse app notarytool submission UUID from:" >&2
  echo "$APP_SUBMIT_JSON" >&2
  exit 1
fi
echo "$APP_UUID" > "$DIST/notarize-app.uuid"
echo "› app submission uuid: $APP_UUID (resumable via: xcrun notarytool wait $APP_UUID --keychain-profile $NOTARY_PROFILE)"
xcrun notarytool wait "$APP_UUID" --keychain-profile "$NOTARY_PROFILE"

echo "› stapling notarization ticket to app"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

# ============================================================================
# 3. Bundle the release artifact
# ============================================================================
echo
echo "=== Packaging release ==="

# Copy the end-user install script and a short README into the stage dir.
cp "$REPO_ROOT/scripts/install-release.sh" "$STAGE/$RELEASE_NAME/install.sh"
chmod +x "$STAGE/$RELEASE_NAME/install.sh"

cat > "$STAGE/$RELEASE_NAME/README.md" <<'EOF'
# imessage-mcp release bundle

This archive contains pre-built, signed, and Apple-notarized binaries.
No Xcode, no Apple Developer Account, no rebuilding required.

## Install

```sh
bash install.sh
```

The installer will:
- Copy `bin/imessage-mcp` to `~/bin/imessage-mcp`
- Copy `iMessage Drafts.app` to `/Applications/iMessage Drafts.app`
- Refresh LaunchServices so macOS finds the new bundle
- Print next steps for granting Full Disk Access + wiring up Claude Desktop

## What you'll need to do manually after install

1. **Grant Full Disk Access** to `~/bin/imessage-mcp` so it can read
   `chat.db` (your iMessage history):
   - System Settings → Privacy & Security → Full Disk Access
   - Click `+`, navigate to `~/bin/imessage-mcp`, select it, toggle on
2. **Configure Claude Desktop** to use the MCP server. Add to
   `~/Library/Application Support/Claude/claude_desktop_config.json`:
   ```json
   {
     "mcpServers": {
       "imessage": { "command": "/Users/YOUR-USERNAME/bin/imessage-mcp" }
     }
   }
   ```
   Then quit Claude Desktop (Cmd+Q) and reopen.
3. **Launch the menu bar app**: `open "/Applications/iMessage Drafts.app"`
   On first popover open, macOS will prompt for Contacts access — approve it.

See the full README in the GitHub repo for the full feature/permission story.
EOF

# Strip any extended attributes / quarantine flags from the stage tree
# before zipping. `ditto -c -k` (which we previously used here) faithfully
# encodes macOS xattrs as AppleDouble `._*` companion files inside the
# zip, which:
#   - bloats the archive
#   - breaks the .app bundle's codesign seal after unzip
#     ("a sealed resource is missing or invalid")
# Modern codesigns are stored in-place — inside the Mach-O for binaries,
# in Contents/_CodeSignature/CodeResources + Contents/CodeResources
# (stapled ticket) for bundles — so clearing xattrs is signature-safe.
xattr -cr "$STAGE/$RELEASE_NAME"

# Zip the stage dir into the release artifact. Using plain `zip` instead
# of `ditto -c -k` because zip doesn't generate AppleDouble files and
# is the universal portable archive format end users expect.
RELEASE_ZIP="$DIST/$RELEASE_NAME.zip"
echo "› writing $RELEASE_ZIP"
cd "$STAGE"
zip -r -q "$RELEASE_ZIP" "$RELEASE_NAME"

# Post-zip verify: ensure the staple still validates on the bundle
# inside the archive. We extract to a temp dir and spctl-assess. If
# this fails, the release zip would Gatekeeper-reject on end-user
# machines — bail out so we don't ship a broken bundle.
echo "› verifying packaged bundle (extract to temp + spctl-assess)"
VERIFY_DIR=$(mktemp -d)
unzip -q "$RELEASE_ZIP" -d "$VERIFY_DIR"
if ! spctl --assess --type execute --verbose=2 "$VERIFY_DIR/$RELEASE_NAME/iMessage Drafts.app" >/dev/null 2>&1; then
  echo "✗ spctl --assess FAILED on the unzipped .app — refusing to ship." >&2
  spctl --assess --type execute --verbose=2 "$VERIFY_DIR/$RELEASE_NAME/iMessage Drafts.app" >&2 || true
  rm -rf "$VERIFY_DIR"
  exit 1
fi
echo "  ✓ Gatekeeper-accepts the bundle"
rm -rf "$VERIFY_DIR"

# Cleanup intermediates. Leaves the release zip and the two .uuid
# files (for post-hoc resume / audit) in $DIST.
rm -rf "$STAGE" "$DIST/notarize-mcp" "$DIST/notarize-app.zip"

# Build succeeded — clear the abort guard so dist/ survives the exit.
trap - INT TERM EXIT

echo
echo "✓ release built: $RELEASE_ZIP"
echo
echo "Next steps:"
echo "  1. Sanity test the bundle locally:"
echo "       cd /tmp && unzip $RELEASE_ZIP && cd $RELEASE_NAME && bash install.sh"
echo "  2. Publish via gh CLI:"
echo "       gh release create $VERSION $RELEASE_ZIP \\"
echo "         --title 'imessage-mcp $VERSION' \\"
echo "         --notes 'See CHANGELOG / commit history.'"
