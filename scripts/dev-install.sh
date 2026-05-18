#!/usr/bin/env bash
#
# Rebuild + install imessage-drafts-mcp into the Messages for AI .app
# bundle for LOCAL DEVELOPMENT.
#
# This is the dev-loop installer — it compiles from source on every run.
# End users should use scripts/install-release.sh (the one bundled inside
# the release zip on GitHub Releases), which installs a pre-built notarized
# .app without needing Bun or a Developer ID cert.
#
# Why install INSIDE the menubar .app:
#
# macOS Sequoia tightened TCC enforcement for bare CLI binaries — granting
# Full Disk Access to a path-based entry in the FDA list no longer
# reliably persists across rebuilds (cdhash changes invalidate the grant,
# and tccutil reset by bundle ID can't address the entry because CLI
# binaries have no CFBundleIdentifier). The practical fix is to place the
# MCP binary inside a proper .app bundle. The bundle's CFBundleIdentifier
# (`com.sunriselabs.messages-for-ai` — shared with the menubar app)
# becomes the TCC identity for both binaries; one FDA grant on the .app
# covers the menubar UI AND the MCP backend.
#
# What this script does:
#   1. `bun build --compile` produces bin/imessage-drafts-mcp.
#   2. xattr -cr clears provenance + quarantine flags.
#   3. codesign --force re-signs the BINARY with --identifier
#      `com.sunriselabs.messages-for-ai` (same as the bundle, so TCC's
#      grant on the .app covers this binary's running process).
#   4. Atomic-mv into /Applications/Messages for AI.app/Contents/MacOS/.
#   5. codesign --force (NO --deep) re-seals the .app bundle so the seal
#      covers the new internal binary. We deliberately avoid --deep
#      because it re-derives each inner Mach-O's identifier from its
#      path basename, clobbering the explicit identifier from step 3.
#   6. Create/refresh a symlink at ~/bin/imessage-drafts-mcp pointing into
#      the .app — so any existing MCP client config pointing at
#      ~/bin/imessage-drafts-mcp keeps working without edits.
#   7. JSON-RPC initialize smoke test confirms the binary boots.
#
# Prerequisite: the menubar .app must already be installed.
# Run `cd menubar && bash scripts/dev-install.sh` first.

set -euo pipefail

cd "$(dirname "$0")/.."

# ─── Configuration ──────────────────────────────────────────────────────────

# The only Apple Developer Team ID accepted for non-adhoc signing.
EXPECTED_TEAM_ID="${EXPECTED_TEAM_ID:-LQ93LRM9QU}"

# Codesign identifier embedded in the inner MCP binary. MUST match the
# bundle's CFBundleIdentifier (`com.sunriselabs.messages-for-ai`) — TCC
# checks the running process's codesign Identifier= against the granted
# identifier, NOT the parent bundle's CFBundleIdentifier. If the inner
# binary's identifier differs from the bundle's, a single FDA grant on
# the .app won't cover the MCP child. macOS's standard convention for
# multi-Mach-O .apps (Xcode, Photoshop, anything with helpers in
# Contents/MacOS/) is for every inner binary to share the bundle's
# identifier — that's what we do here.
#
# Same identifier for dev + release is OK: TCC keys grants by
# (identifier, team-id), tolerant of cdhash changes. A dev rebuild
# updates the cdhash but doesn't invalidate the release install's FDA
# grant because identifier+team are unchanged.
IDENTIFIER="${IMESSAGE_MCP_IDENTIFIER:-com.sunriselabs.messages-for-ai}"

# Absolute paths to macOS-system binaries. Defends against PATH-shimmed
# `security` / `codesign` (e.g. a malicious npm postinstall planting an
# attacker binary on $PATH).
SECURITY=/usr/bin/security
CODESIGN=/usr/bin/codesign
AWK=/usr/bin/awk

BIN_SRC="bin/imessage-drafts-mcp"
APP="/Applications/Messages for AI.app"
APP_BIN="${APP}/Contents/MacOS/imessage-drafts-mcp"
SYMLINK="${HOME}/bin/imessage-drafts-mcp"
ENTITLEMENTS="menubar/scripts/messages-for-ai.entitlements"

# ─── Preflight ──────────────────────────────────────────────────────────────

if [[ ! -d "$APP" ]]; then
  echo "✗ menubar .app not found at: $APP" >&2
  echo "  Install the menubar app first:" >&2
  echo "    (cd menubar && bash scripts/dev-install.sh)" >&2
  exit 1
fi

if [[ ! -f "$ENTITLEMENTS" ]]; then
  echo "✗ menubar entitlements file missing: $ENTITLEMENTS" >&2
  exit 1
fi

# ─── Build ──────────────────────────────────────────────────────────────────

echo "› bun build --compile"
bun build src/index.ts --compile --outfile "$BIN_SRC"

echo "› clearing xattrs on build output"
xattr -c "$BIN_SRC"

# ─── Sign the binary with the bundle's identifier ───────────────────────────
#
# The inner MCP binary must share the bundle's CFBundleIdentifier
# (`com.sunriselabs.messages-for-ai` — set by the menubar's dev-install)
# so that one FDA grant on the .app covers the MCP child process. TCC
# checks the running process's codesign Identifier= against the granted
# identifier as strings; mismatched identifiers = no grant match.

SIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY=$("$SECURITY" find-identity -v -p codesigning 2>/dev/null \
    | "$AWK" -F\" -v team="$EXPECTED_TEAM_ID" \
        '/Developer ID Application/ && $2 ~ "\\("team"\\)$" {print $2; exit}')
fi

if [[ -n "$SIGN_IDENTITY" ]]; then
  DETECTED_TEAM=$(echo "$SIGN_IDENTITY" | sed -nE 's/.*\(([A-Z0-9]+)\)$/\1/p')
  if [[ "$DETECTED_TEAM" != "$EXPECTED_TEAM_ID" ]]; then
    echo "✗ signing identity Team ID '$DETECTED_TEAM' ≠ expected '$EXPECTED_TEAM_ID'" >&2
    exit 1
  fi
  echo "› signing binary with Developer ID: $SIGN_IDENTITY"
  "$CODESIGN" --force --sign "$SIGN_IDENTITY" --identifier "$IDENTIFIER" --options=runtime "$BIN_SRC"
else
  echo "› no Developer ID cert from team $EXPECTED_TEAM_ID found; falling back to adhoc"
  echo "  ⚠  FDA grants for adhoc-signed bundles are unstable across rebuilds."
  "$CODESIGN" --force --sign - --identifier "$IDENTIFIER" --options=runtime "$BIN_SRC"
fi

# ─── Install into the .app bundle ───────────────────────────────────────────

echo "› installing binary into $APP_BIN"
cp "$BIN_SRC" "${APP_BIN}.new"
xattr -c "${APP_BIN}.new"
mv "${APP_BIN}.new" "$APP_BIN"

# ─── Re-seal the .app bundle ────────────────────────────────────────────────
#
# Re-signs the bundle at its root, updating the seal to cover the new
# inner MCP binary. We DELIBERATELY DO NOT pass --deep here, because
# --deep walks every inner Mach-O and re-derives each one's identifier
# from its path basename — which clobbers the explicit `--identifier
# "$IDENTIFIER"` we set above and replaces it with the path-derived
# default `imessage-drafts-mcp` (no reverse-DNS prefix). That would
# leave the inner binary with an identity TCC can't match against any
# FDA grant. Discovered the hard way in v0.2.0 development; never use
# --deep on a bundle whose inner binaries you've already signed with
# explicit identifiers.
#
# We re-use the menubar's entitlements file because the same .app houses
# both binaries. Both share the bundle's CFBundleIdentifier (and now
# also share the inner Identifier= from explicit signing), so the same
# entitlements declaration applies to both.

if [[ -n "$SIGN_IDENTITY" ]]; then
  echo "› re-sealing .app bundle with Developer ID: $SIGN_IDENTITY"
  "$CODESIGN" --force --sign "$SIGN_IDENTITY" --options=runtime \
    --entitlements "$ENTITLEMENTS" "$APP"
else
  echo "› re-sealing .app bundle adhoc"
  "$CODESIGN" --force --sign - --options=runtime "$APP"
fi

# ─── Verify the bundle seal ─────────────────────────────────────────────────

echo "› verifying .app signature seal"
if ! "$CODESIGN" --verify --strict --verbose "$APP" 2>&1; then
  echo "✗ codesign --verify failed on $APP" >&2
  exit 1
fi

echo "› binary identity (inside bundle):"
"$CODESIGN" -dv --verbose=2 "$APP_BIN" 2>&1 | grep -E "Identifier|Authority|TeamIdentifier" || true
echo "› bundle identity:"
"$CODESIGN" -dv --verbose=2 "$APP" 2>&1 | grep -E "Identifier|Authority|TeamIdentifier" || true

# ─── Maintain ~/bin/ symlink for backward compat ───────────────────────────
#
# MCP client configs that point at ~/bin/imessage-drafts-mcp (the v0.1.x
# convention) keep working — the symlink resolves to the .app-internal
# binary at exec time. TCC sees the binary's actual path inside the .app
# and applies the bundle's grant.

echo "› maintaining symlink: $SYMLINK → $APP_BIN"
mkdir -p "$(dirname "$SYMLINK")"
ln -sf "$APP_BIN" "$SYMLINK"

# ─── Smoke test ─────────────────────────────────────────────────────────────

echo "› smoke initialize (via .app-internal binary)"
SMOKE_STDERR=$(mktemp)
SMOKE_OUTPUT=$(echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"install-smoke","version":"0"}}}' | "$APP_BIN" 2>"$SMOKE_STDERR" | head -1)
if echo "$SMOKE_OUTPUT" | grep -q '"serverInfo"'; then
  echo "  ok"
  rm -f "$SMOKE_STDERR"
else
  echo "  FAILED — stdout: $SMOKE_OUTPUT" >&2
  echo "  FAILED — stderr:" >&2
  cat "$SMOKE_STDERR" >&2
  rm -f "$SMOKE_STDERR"
  exit 1
fi

echo
echo "installed: $APP_BIN"
echo "           $SYMLINK -> $APP_BIN"
echo
echo "MCP client configs can point at EITHER path. Both resolve to the"
echo "same binary, which inherits FDA from the .app bundle's TCC identity."
echo
echo "Restart Claude Desktop (and any other MCP clients) to pick up the"
echo "new binary."
