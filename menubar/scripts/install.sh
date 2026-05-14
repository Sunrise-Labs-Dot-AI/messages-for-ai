#!/usr/bin/env bash
#
# Build and install the iMessage Drafts menu bar app.
#
# This produces a proper .app bundle (rather than a bare executable) so:
#   - macOS can show a real app icon / name in TCC prompts.
#   - LSUIElement = true keeps the app out of the Dock and ⌘-Tab switcher.
#   - The Automation permission grant is per-bundle-id and survives rebuilds.
#
# After install, launch via:    open ~/Applications/iMessage\ Drafts.app
# Or set it as a Login Item:    System Settings → General → Login Items.

set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="iMessage Drafts"
BUNDLE_ID="com.local.imessage-drafts"
INSTALL_ROOT="${HOME}/Applications"
APP="${INSTALL_ROOT}/${APP_NAME}.app"
EXE_NAME="iMessageDraftsMenu"

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
