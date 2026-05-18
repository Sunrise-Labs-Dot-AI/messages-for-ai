#!/usr/bin/env bash
#
# DEV build + install of the Messages for AI menu bar app.
#
# This is the dev-loop installer. End users should get the release zip
# from GitHub Releases and run its bundled `install.sh` (sourced from
# scripts/install-release.sh in this repo) — that path installs a pre-
# built notarized .app without needing Xcode or a Developer ID cert.
#
# This script (in contrast):
#   - Compiles the menu bar app from source via `swift build -c release`.
#   - Assembles a proper `.app` bundle so macOS shows a real icon / name
#     in TCC prompts.
#   - Sets LSUIElement = true so the app lives in the menu bar with no
#     Dock icon or ⌘-Tab presence.
#   - Codesigns with a Developer ID cert matching EXPECTED_TEAM_ID if
#     present, falls back to adhoc with a warning.
#
# After install, launch via:    open /Applications/iMessage\ Drafts.app
# Or set it as a Login Item:    System Settings → General → Login Items.
#
# Install destination: /Applications by default. This is where Finder's
# sidebar "Applications" item points and where Launchpad indexes. Override
# with INSTALL_ROOT=/some/other/path if /Applications isn't writable (e.g.
# on a managed Mac):
#   INSTALL_ROOT="$HOME/Applications" bash scripts/dev-install.sh

set -euo pipefail

cd "$(dirname "$0")/.."

# ─── Configuration ──────────────────────────────────────────────────────────

# The only Apple Developer Team ID accepted for non-adhoc signing.
# Auto-detected `Developer ID Application: ...` certs whose parenthesized
# Team ID doesn't match this value are REJECTED — script falls back to
# adhoc rather than silently signing with an attacker-planted cert.
EXPECTED_TEAM_ID="${EXPECTED_TEAM_ID:-LQ93LRM9QU}"

# Absolute paths to macOS-system binaries. Defends against PATH-shimmed
# `security` / `codesign` (e.g. a malicious npm postinstall planting an
# attacker binary on $PATH).
SECURITY=/usr/bin/security
CODESIGN=/usr/bin/codesign
AWK=/usr/bin/awk

APP_NAME="Messages for AI"
# Bundle ID history:
#   `com.local.imessage-drafts` (v0.1.x dev, poisoned by an early build
#     that lacked NSContactsUsageDescription)
#   → `com.sunriselabs.imessage-drafts` (v0.1.x release)
#   → `com.sunriselabs.messages-for-ai` (current; v0.2.0 rename)
# macOS TCC's opaque "this bundle is suspicious" cache survives both
# `tccutil reset` and `killall tccd`. Each fresh bundle ID dodges the
# whole apparatus and is treated as a new app for TCC purposes. The
# `.local.` namespace is reserved for Bonjour multicast DNS anyway —
# `com.sunriselabs.*` matches the GitHub org and is the conventional
# reverse-DNS shape for signed dev/release tools.
BUNDLE_ID="com.sunriselabs.messages-for-ai"
# IDs that existed in v0.1.x installs and may have left orphan TCC
# entries on existing user machines. Surface them in the tccutil cleanup
# hint after install. Do NOT include the current BUNDLE_ID here.
LEGACY_BUNDLE_IDS=("com.local.imessage-drafts" "com.sunriselabs.imessage-drafts")
INSTALL_ROOT="${INSTALL_ROOT:-/Applications}"
APP="${INSTALL_ROOT}/${APP_NAME}.app"
LEGACY_APP="${HOME}/Applications/${APP_NAME}.app"
EXE_NAME="MessagesForAIMenu"

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
  echo "  Either re-run with sudo:    sudo bash scripts/dev-install.sh" >&2
  echo "  Or install to your per-user folder:" >&2
  echo "    INSTALL_ROOT=\"\$HOME/Applications\" bash scripts/dev-install.sh" >&2
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
  <string>Messages for AI sends staged iMessage drafts via Messages.app.</string>
  <key>NSContactsUsageDescription</key>
  <string>Messages for AI reads your Contacts to resolve recipient names. The same data Messages.app shows, including iCloud-synced contacts. The exported list is written only to ~/.messages-mcp/contacts-cache.json on this Mac and never leaves the machine.</string>
  <key>NSHumanReadableCopyright</key>
  <string>Local-only utility. No data leaves this Mac.</string>
</dict>
</plist>
EOF

echo "› clearing xattrs"
xattr -cr "$APP"

# Pick a codesigning identity. Order of preference:
#   1. $CODESIGN_IDENTITY (explicit override — bypasses Team ID check;
#      caller's responsibility).
#   2. First `Developer ID Application: ... (<EXPECTED_TEAM_ID>)` cert
#      in the keychain.
#   3. Adhoc (`-`) as a last-resort fallback.
#
# Why this matters: macOS Sequoia silently blocks CNContactStore.
# requestAccess for any adhoc-signed app, regardless of bundle ID,
# Info.plist, or TCC state — verified empirically. A real Developer
# ID cert unblocks it. Adhoc still works for sending iMessages via
# Automation, just not for CNContacts. The CONTACTS_REQUIRE_DEVID env
# var lets a hostile-environment build fail loudly instead of silently
# falling back.
SIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  # Match the FULL identity line including the Team ID suffix. This
  # rejects an attacker-planted "Developer ID Application: Victim
  # (FAKEID)" cert because (FAKEID) ≠ (EXPECTED_TEAM_ID).
  SIGN_IDENTITY=$("$SECURITY" find-identity -v -p codesigning 2>/dev/null \
    | "$AWK" -F\" -v team="$EXPECTED_TEAM_ID" \
        '/Developer ID Application/ && $2 ~ "\\("team"\\)$" {print $2; exit}')
fi

ENTITLEMENTS="$(dirname "$0")/messages-for-ai.entitlements"

# Sign the inner Mach-Os explicitly with the bundle's identifier, then
# seal the bundle WITHOUT --deep. See scripts/README.md (Architecture
# section) for the full reasoning — short version: `codesign --deep`
# overrides any --identifier flag on inner Mach-Os and re-derives each
# from its path basename, leaving the menubar binary with Identifier=
# MessagesForAIMenu (path-derived, no reverse-DNS prefix), which TCC
# cannot match against any grant. We need the menubar binary's process
# identity to equal the bundle's CFBundleIdentifier so the FDA grant
# on the .app covers it.
#
# This script signs ONLY the menubar binary + bundle. If the MCP
# binary is already inside the bundle (from a prior repo-root
# dev-install.sh run), the repo-root dev-install.sh re-signs it
# afterwards. We deliberately avoid --deep so that, if the MCP binary
# IS already there, we don't clobber its explicit identifier.

if [[ -n "$SIGN_IDENTITY" ]]; then
  # Defense-in-depth: re-verify Team ID embedded in the chosen identity.
  # The awk filter above already enforces this for auto-detection; a
  # CODESIGN_IDENTITY override skips that filter.
  DETECTED_TEAM=$(echo "$SIGN_IDENTITY" | sed -nE 's/.*\(([A-Z0-9]+)\)$/\1/p')
  if [[ "$DETECTED_TEAM" != "$EXPECTED_TEAM_ID" ]]; then
    echo "✗ signing identity Team ID '$DETECTED_TEAM' ≠ expected '$EXPECTED_TEAM_ID'" >&2
    echo "  Refusing to sign with an unknown identity." >&2
    exit 1
  fi
  SIGN_ARGS=(--force --sign "$SIGN_IDENTITY")
  ADHOC=0
else
  if [[ "${CONTACTS_REQUIRE_DEVID:-}" == "1" ]]; then
    echo "✗ no Developer ID Application cert from team $EXPECTED_TEAM_ID found, but CONTACTS_REQUIRE_DEVID=1" >&2
    echo "  Install one via Xcode → Settings → Accounts → Manage Certificates," >&2
    echo "  then re-run." >&2
    exit 1
  fi
  echo "› no Developer ID cert from team $EXPECTED_TEAM_ID found; falling back to adhoc"
  echo "  ⚠  CNContactStore.requestAccess will fail under adhoc signing —"
  echo "     Contacts resolution will be unavailable until you install a"
  echo "     Developer ID Application cert. Sending iMessages still works."
  SIGN_ARGS=(--force --sign -)
  ADHOC=1
fi

# Sign the menubar binary in place with the bundle's identifier.
echo "› signing menubar binary with --identifier ${BUNDLE_ID}"
"$CODESIGN" "${SIGN_ARGS[@]}" \
  --identifier "${BUNDLE_ID}" --options=runtime \
  "$APP/Contents/MacOS/$EXE_NAME"

# If a sibling MCP binary already lives inside the bundle (from a
# prior repo-root dev-install.sh run), re-sign it too — with the SAME
# bundle identifier — so the bundle seal below validates a consistent
# inner-identifier state. The repo-root dev-install.sh will re-sign
# it again with fresh build output, but signing it here keeps the
# intermediate state valid.
MCP_SIBLING="$APP/Contents/MacOS/imessage-drafts-mcp"
if [[ -x "$MCP_SIBLING" ]]; then
  echo "› re-signing existing MCP sibling with --identifier ${BUNDLE_ID}"
  "$CODESIGN" "${SIGN_ARGS[@]}" \
    --identifier "${BUNDLE_ID}" --options=runtime \
    "$MCP_SIBLING"
fi

# Seal the bundle. NO --deep — the explicit per-file signing above
# put the right identifiers on each inner Mach-O; --deep would now
# overwrite them.
#
# --entitlements passes the per-feature permissions Hardened Runtime
# requires for Contacts framework access and Apple Events. Without
# the addressbook entitlement, CNContactStore.requestAccess throws
# "Access Denied" synchronously even for Developer-ID-signed apps.
if [[ "$ADHOC" -eq 1 ]]; then
  # Adhoc bundle seal — no entitlements file (adhoc-signed bundles
  # can't claim entitlements that require Apple authorization).
  echo "› sealing .app bundle adhoc"
  "$CODESIGN" "${SIGN_ARGS[@]}" \
    --identifier "${BUNDLE_ID}" --options=runtime "$APP"
else
  echo "› sealing .app bundle with Developer ID + entitlements"
  "$CODESIGN" "${SIGN_ARGS[@]}" \
    --identifier "${BUNDLE_ID}" --options=runtime \
    --entitlements "$ENTITLEMENTS" "$APP"
fi

echo "› verifying signature seal"
if ! "$CODESIGN" --verify --strict --verbose "$APP" 2>&1; then
  echo "✗ codesign --verify failed on $APP" >&2
  exit 1
fi
"$CODESIGN" -dv --verbose=2 "$APP" 2>&1 | grep -E "Identifier|Authority|TeamIdentifier" || true

# Re-register the bundle with LaunchServices. Without this, `open
# "$APP"` can fail with error -600 (procNotFound) if LaunchServices
# still has the legacy ~/Applications/ path cached — common on machines
# that previously installed there. lsregister with -f forces a refresh
# of the bundle metadata at the new location.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
  echo "› refreshing LaunchServices registration"
  "$LSREGISTER" -f "$APP" >/dev/null 2>&1 || true
fi

# Add the bundle to Gatekeeper's trusted-apps list. Without this,
# adhoc-signed apps (signature=adhoc, TeamIdentifier=not set) can
# trigger an "Access Denied" rejection from CNContactStore.requestAccess
# even when NSContactsUsageDescription is set and TCC has no recorded
# denial — verified empirically on macOS Sequoia. spctl --add registers
# the path as an approved source, which lets the TCC subsystem trust
# the calling process for sensitive APIs.
echo "› adding to Gatekeeper trusted apps"
spctl --add "$APP" 2>/dev/null || true

# Remove the legacy ~/Applications/Messages for AI.app left over from
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
