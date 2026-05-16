#!/usr/bin/env bash
#
# End-user installer for the pre-built imessage-mcp release. This script
# ships INSIDE the release zip — it doesn't rebuild from source. It just
# copies the already-signed-and-notarized artifacts into the conventional
# locations and prints next steps.
#
# If you're a developer building from source, use scripts/install.sh and
# menubar/scripts/install.sh in the repo root instead.

set -euo pipefail

# Resolve script directory (works whether invoked via `bash install.sh`
# from the unzip target, or `./install.sh`).
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

BIN_SRC="$SCRIPT_DIR/bin/imessage-mcp"
APP_SRC="$SCRIPT_DIR/iMessage Drafts.app"
BIN_DEST="$HOME/bin/imessage-mcp"
APP_DEST="/Applications/iMessage Drafts.app"

# Sanity check the bundle.
if [[ ! -x "$BIN_SRC" ]]; then
  echo "✗ missing $BIN_SRC — is the release archive intact?" >&2
  exit 1
fi
if [[ ! -d "$APP_SRC" ]]; then
  echo "✗ missing $APP_SRC — is the release archive intact?" >&2
  exit 1
fi

echo "=== Installing imessage-mcp ==="

# ---------------------------------------------------------------------------
# imessage-mcp binary → ~/bin/
# ---------------------------------------------------------------------------
echo
echo "› ~/bin/imessage-mcp"
mkdir -p "$HOME/bin"
# Use atomic copy + rename so a running MCP child doesn't get its file
# yanked mid-exec.
cp "$BIN_SRC" "$BIN_DEST.new"
xattr -cr "$BIN_DEST.new" || true
mv "$BIN_DEST.new" "$BIN_DEST"
chmod +x "$BIN_DEST"

# Sanity-check the signature was preserved through the copy.
if codesign -dv "$BIN_DEST" 2>&1 | grep -q "Authority=Developer ID Application"; then
  echo "  ✓ signature intact"
else
  echo "  ⚠  signature could not be verified — the binary may still run, but" >&2
  echo "     you may see Gatekeeper warnings on first launch." >&2
fi

# ---------------------------------------------------------------------------
# Menu bar app → /Applications/
# ---------------------------------------------------------------------------
echo
echo "› /Applications/iMessage Drafts.app"
if [[ ! -w "/Applications" ]]; then
  echo "✗ /Applications is not writable by $USER." >&2
  echo "  Either re-run this script with sudo, or install the app to your" >&2
  echo "  per-user folder manually: cp -R \"$APP_SRC\" ~/Applications/" >&2
  exit 1
fi

# Remove any existing copy at the same path so we don't leave stale
# resource forks. Use rsync for the copy to handle the (admittedly
# unlikely) case where the app contains symlinks.
rm -rf "$APP_DEST"
ditto "$APP_SRC" "$APP_DEST"

# Remove the legacy ~/Applications/ copy from old installs that wrote there.
LEGACY_APP="$HOME/Applications/iMessage Drafts.app"
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

if codesign -dv "$APP_DEST" 2>&1 | grep -q "Authority=Developer ID Application"; then
  echo "  ✓ signature intact"
fi

# ---------------------------------------------------------------------------
# Smoke test
# ---------------------------------------------------------------------------
echo
echo "› smoke test (initialize call against the MCP)"
SMOKE_OUTPUT=$(echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"install-smoke","version":"0"}}}' | "$BIN_DEST" 2>&1 | head -1)
if echo "$SMOKE_OUTPUT" | grep -q '"serverInfo"'; then
  echo "  ✓ MCP responds to initialize"
else
  echo "  ⚠  smoke test failed: $SMOKE_OUTPUT" >&2
fi

# ---------------------------------------------------------------------------
# Next steps printout
# ---------------------------------------------------------------------------
cat <<EOF

==================================================================
✓ Install complete.

Three things you need to do manually:

1. GRANT FULL DISK ACCESS to the MCP binary so it can read chat.db
   (your iMessage history):

     System Settings → Privacy & Security → Full Disk Access
     Click "+" → navigate to ~/bin/imessage-mcp → select → toggle on

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
     "iMessage Drafts Would Like to Access Your Contacts"
   Click OK. The app populates a sidecar (~/.imessage-mcp/contacts-cache.json)
   that the MCP reads to resolve recipient names.

After these three steps, in a Claude Desktop chat ask:
   "call imessage_mcp_health_check"
to verify everything is wired up.
==================================================================
EOF
