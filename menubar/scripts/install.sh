#!/usr/bin/env bash
#
# Build and install the iMessage Drafts menu bar app.
#
# This produces a proper .app bundle (rather than a bare executable) so:
#   - macOS can show a real app icon / name in TCC prompts.
#   - LSUIElement = true keeps the app out of the Dock and ⌘-Tab switcher.
#   - The Automation permission grant is per-bundle-id and survives rebuilds.
#
# After install, launch via:    open /Applications/iMessage\ Drafts.app
# Or set it as a Login Item:    System Settings → General → Login Items.
#
# Install destination: /Applications by default. This is where Finder's
# sidebar "Applications" item points and where Launchpad indexes. Override
# with INSTALL_ROOT=/some/other/path if /Applications isn't writable (e.g.
# on a managed Mac):
#   INSTALL_ROOT="$HOME/Applications" bash scripts/install.sh

set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="iMessage Drafts"
BUNDLE_ID="com.local.imessage-drafts"
INSTALL_ROOT="${INSTALL_ROOT:-/Applications}"
APP="${INSTALL_ROOT}/${APP_NAME}.app"
LEGACY_APP="${HOME}/Applications/${APP_NAME}.app"
EXE_NAME="iMessageDraftsMenu"

# Pre-flight: make sure we can write to the install root before doing the
# slow swift build. /Applications is writable by the local admin user on
# a default macOS setup (no sudo required), but managed / multi-user Macs
# can have it locked down.
if [[ ! -d "$INSTALL_ROOT" ]]; then
  echo "✗ install root does not exist: $INSTALL_ROOT" >&2
  exit 1
fi
if [[ ! -w "$INSTALL_ROOT" ]]; then
  echo "✗ install root is not writable by $USER: $INSTALL_ROOT" >&2
  echo "  Either re-run with sudo:    sudo bash scripts/install.sh" >&2
  echo "  Or install to your per-user folder:" >&2
  echo "    INSTALL_ROOT=\"\$HOME/Applications\" bash scripts/install.sh" >&2
  exit 1
fi

echo "› swift build -c release"
swift build -c release

BIN=".build/release/${EXE_NAME}"
if [[ ! -x "$BIN" ]]; then
  echo "expected binary at $BIN was not produced" >&2
  exit 1
fi

echo "› assembling ${APP}"
mkdir -p "${APP}/Contents/MacOS"
mkdir -p "${APP}/Contents/Resources"

# Atomic install of the executable so a running instance isn't ripped out
# from under itself.
cp "$BIN" "${APP}/Contents/MacOS/${EXE_NAME}.new"
xattr -c "${APP}/Contents/MacOS/${EXE_NAME}.new"
mv "${APP}/Contents/MacOS/${EXE_NAME}.new" "${APP}/Contents/MacOS/${EXE_NAME}"

cat > "${APP}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>${EXE_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
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

echo "› clearing xattrs + re-signing with stable identifier (${BUNDLE_ID}) + hardened runtime"
xattr -cr "$APP"
# Hardened Runtime: enforces library validation, blocks dyld injection,
# disables several other class of gadget attacks. Even though we're
# adhoc-signing, the runtime flags still kick in.
codesign --force --deep --sign - --identifier "${BUNDLE_ID}" --options=runtime "$APP"

echo "› verifying signature"
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Signature" || true

# Remove the legacy ~/Applications/iMessage Drafts.app left over from
# earlier installs that wrote there. Two reasons: (1) Spotlight indexes
# both locations and would otherwise return the stale per-user copy
# half the time; (2) the user's "I quit the app — where do I find it?"
# muscle memory points at Finder → Applications (the /Applications
# folder, surfaced in Finder's sidebar). Done AFTER the new install
# succeeds so a failed install never leaves the user with neither copy.
if [[ -d "$LEGACY_APP" && "$LEGACY_APP" != "$APP" ]]; then
  echo "› removing legacy install at $LEGACY_APP"
  rm -rf "$LEGACY_APP"
fi

echo
echo "installed: $APP"
echo
echo "Next steps:"
echo "  1) Launch:  open \"$APP\""
echo "  2) On the first Send, macOS will prompt to allow ${APP_NAME} to"
echo "     control Messages.app — click OK."
echo "  3) Open-at-login is on by default — the app auto-registers itself"
echo "     via SMAppService the first time it runs. Toggle off via the"
echo "     popover footer, or via System Settings → General → Login Items."
