#!/usr/bin/env bash
#
# End-user installer for the pre-built imessage-drafts-mcp release. This script
# ships INSIDE the release zip — it doesn't rebuild from source. It just
# copies the already-signed-and-notarized artifacts into the conventional
# locations and prints next steps.
#
# If you're a developer building from source, use scripts/dev-install.sh
# and menubar/scripts/dev-install.sh in the repo root instead.

set -euo pipefail

# ─── Configuration ──────────────────────────────────────────────────────────

# The only Apple Developer Team ID this installer accepts. If the bundle
# extracted from the release zip was signed by a different Team ID
# (e.g. a phishing-site forged release signed under an attacker's
# Developer ID), the install ABORTS with a clear error rather than
# silently installing the attacker's binary. Override only if you know
# you're testing against a fork.
EXPECTED_TEAM_ID="${EXPECTED_TEAM_ID:-LQ93LRM9QU}"

# Absolute paths to macOS-system binaries. Defends against PATH-shimmed
# `codesign` / `spctl` (e.g. a malicious shell rc planting an attacker
# binary on $PATH).
CODESIGN=/usr/bin/codesign
SPCTL=/usr/sbin/spctl

# Resolve script directory (works whether invoked via `bash install.sh`
# from the unzip target, or `./install.sh`). Also normalize with -P
# (physical, follows symlinks) so we have a canonical path for sanity
# checks below.
SCRIPT_DIR="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" && pwd -P )"
cd "$SCRIPT_DIR"

BIN_SRC="$SCRIPT_DIR/bin/imessage-drafts-mcp"
APP_SRC="$SCRIPT_DIR/Messages for AI.app"
BIN_DEST="$HOME/bin/imessage-drafts-mcp"
APP_DEST="/Applications/Messages for AI.app"

# ─── Sanity check the archive ───────────────────────────────────────────────

if [[ ! -x "$BIN_SRC" ]]; then
  echo "✗ missing $BIN_SRC — is the release archive intact?" >&2
  exit 1
fi
if [[ ! -d "$APP_SRC" ]]; then
  echo "✗ missing $APP_SRC — is the release archive intact?" >&2
  exit 1
fi

# ─── Verify the archive's signing identity matches EXPECTED_TEAM_ID ─────────
#
# This is the headline check that defends against a phishing-site
# release. Even if the user is tricked into downloading a malicious
# zip, the bundle inside will have been signed by the attacker's
# Developer ID — its embedded TeamIdentifier won't match ours, and
# this script will refuse to install it. The check runs BEFORE any
# files are copied to destination paths, so a refused install leaves
# the user's existing setup untouched.

echo "=== Verifying release artifact identity ==="

verify_team_id() {
  local target="$1"
  local kind="$2"
  local detected
  detected=$("$CODESIGN" -dv --verbose=2 "$target" 2>&1 | sed -nE 's/^TeamIdentifier=([A-Z0-9]+)$/\1/p' | head -1)
  if [[ -z "$detected" ]]; then
    echo "✗ $kind has no embedded TeamIdentifier — refusing to install." >&2
    echo "  Expected signature from Team ID $EXPECTED_TEAM_ID." >&2
    return 1
  fi
  if [[ "$detected" != "$EXPECTED_TEAM_ID" ]]; then
    echo "✗ $kind is signed by Team ID '$detected', expected '$EXPECTED_TEAM_ID'." >&2
    echo "  This release zip may be a forgery — REFUSING to install." >&2
    echo "  If you intentionally built from a fork, set EXPECTED_TEAM_ID=$detected." >&2
    return 1
  fi
  # Run the actual seal verification too. `codesign --verify` walks the
  # binary and checks every signed component against the embedded code
  # directory. A passing exit code means the contents match the signature.
  if ! "$CODESIGN" --verify --strict --verbose "$target" >/dev/null 2>&1; then
    echo "✗ $kind failed codesign --verify (seal is corrupted or modified)." >&2
    return 1
  fi
  echo "  ✓ $kind: Team $detected, seal intact"
}

verify_team_id "$BIN_SRC" "imessage-drafts-mcp binary" || exit 1
verify_team_id "$APP_SRC" "Messages for AI.app" || exit 1

# Gatekeeper-assess the .app. This is the system's own "would I allow
# this app to run?" check, which incorporates notarization status.
echo "› Gatekeeper assess on Messages for AI.app"
if ! "$SPCTL" --assess --type execute "$APP_SRC" 2>&1; then
  echo "✗ Gatekeeper rejected $APP_SRC — refusing to install." >&2
  exit 1
fi

echo "=== Installing imessage-drafts-mcp ==="

# ─── imessage-drafts-mcp binary → ~/bin/ ───────────────────────────────────────────

echo
echo "› ~/bin/imessage-drafts-mcp"
mkdir -p "$HOME/bin"
# Atomic copy + rename so a running MCP child doesn't get its file
# yanked mid-exec.
cp "$BIN_SRC" "$BIN_DEST.new"
xattr -cr "$BIN_DEST.new" || true
mv "$BIN_DEST.new" "$BIN_DEST"
chmod +x "$BIN_DEST"

# Confirm the seal survived the copy.
if ! "$CODESIGN" --verify --strict --verbose "$BIN_DEST" >/dev/null 2>&1; then
  echo "✗ post-install codesign --verify failed on $BIN_DEST" >&2
  exit 1
fi
echo "  ✓ signature preserved through copy"

# ─── Menu bar app → /Applications/ ──────────────────────────────────────────

echo
echo "› /Applications/Messages for AI.app"
if [[ ! -w "/Applications" ]]; then
  echo "✗ /Applications is not writable by $USER." >&2
  echo "  Either re-run this script with sudo, or install the app to your" >&2
  echo "  per-user folder manually: cp -R \"$APP_SRC\" ~/Applications/" >&2
  exit 1
fi

# Remove any existing copy at the same path so we don't leave stale
# resource forks. We've already verified the source bundle's identity
# above, so this rm is safe even though TOCTOU-wise an attacker
# couldn't have raced us to substitute it.
rm -rf "$APP_DEST"
ditto "$APP_SRC" "$APP_DEST"

# Re-verify the seal on the installed copy. ditto preserves attributes
# but the bytes are different files now, so this is a separate signature
# check from the one we did on the source.
if ! "$CODESIGN" --verify --strict --verbose "$APP_DEST" >/dev/null 2>&1; then
  echo "✗ post-install codesign --verify failed on $APP_DEST" >&2
  exit 1
fi
echo "  ✓ signature preserved through copy"

# Remove the legacy ~/Applications/ copy from old installs that wrote there.
LEGACY_APP="$HOME/Applications/Messages for AI.app"
if [[ -d "$LEGACY_APP" ]]; then
  echo "  › removing legacy install at $LEGACY_APP"
  rm -rf "$LEGACY_APP"
fi

# Refresh LaunchServices so `open` finds the new bundle (otherwise the
# cached path can win and `open` returns error -600).
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$APP_DEST" >/dev/null 2>&1 || true
fi

# ─── Smoke test ─────────────────────────────────────────────────────────────

echo
echo "› smoke test (initialize call against the MCP)"
SMOKE_OUTPUT=$(echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"install-smoke","version":"0"}}}' | "$BIN_DEST" 2>&1 | head -1)
if echo "$SMOKE_OUTPUT" | grep -q '"serverInfo"'; then
  echo "  ✓ MCP responds to initialize"
else
  echo "  ⚠  smoke test failed: $SMOKE_OUTPUT" >&2
fi

# ─── Next steps printout ────────────────────────────────────────────────────

cat <<EOF

==================================================================
✓ Install complete. Bundle signed by Team $EXPECTED_TEAM_ID, seal verified.

Three things you need to do manually:

1. GRANT FULL DISK ACCESS to the MCP binary so it can read chat.db
   (your iMessage history):

     System Settings → Privacy & Security → Full Disk Access
     Click "+" → navigate to ~/bin/imessage-drafts-mcp → select → toggle on

2. CONFIGURE CLAUDE DESKTOP to use the MCP. Edit:

     ~/Library/Application Support/Claude/claude_desktop_config.json

   Add (or merge into existing mcpServers):

     {
       "mcpServers": {
         "imessage": {
           "command": "$BIN_DEST"
         }
       }
     }

   Then quit Claude Desktop entirely (Cmd+Q on the Claude menu, NOT
   just closing the window) and reopen it.

3. LAUNCH THE MENU BAR APP:

     open "$APP_DEST"

   On first popover open, macOS will ask:
     "Messages for AI Would Like to Access Your Contacts"
   Click OK. The app populates a sidecar (~/.messages-mcp/contacts-cache.json)
   that the MCP reads to resolve recipient names.

After these three steps, in a Claude Desktop chat ask:
   "call health_check"
to verify everything is wired up.
==================================================================
EOF
