#!/usr/bin/env bash
#
# Rebuild + install imessage-drafts-mcp into ~/bin/ for LOCAL DEVELOPMENT.
#
# This is the dev-loop installer — it compiles from source on every run.
# End users should use scripts/install-release.sh (the one bundled inside
# the release zip on GitHub Releases), which installs a pre-built notarized
# binary without needing Bun or a Developer ID cert.
#
# What this script does:
#   1. `bun build --compile` produces bin/imessage-drafts-mcp.
#   2. xattr -cr clears provenance + quarantine flags that would otherwise
#      flag the binary as untrusted on next launch.
#   3. codesign --force re-signs with a stable identifier
#      `com.local.messages-mcp.dev` (distinct from the release identifier
#      `com.sunriselabs.messages-mcp` — see below). If a Developer ID
#      Application cert from the EXPECTED_TEAM_ID is present in the
#      keychain it's used; otherwise falls back to adhoc with a warning.
#   4. Atomic-mv into ~/bin/imessage-drafts-mcp.
#   5. codesign --verify confirms the signature is well-formed.
#   6. JSON-RPC initialize smoke test confirms the binary boots.
#
# Restart any MCP clients that have already spawned the old binary
# (Claude Desktop, Claude Code, Codex CLI) so they fork a fresh child.
#
# Identifier conventions:
#   - Dev builds (this script):              com.local.messages-mcp.dev
#   - Release builds (build-release.sh):     com.sunriselabs.messages-mcp
#
# We deliberately use DIFFERENT identifiers because TCC keys the Full
# Disk Access grant off the codesigning identity. Running this dev
# script after installing a release would otherwise overwrite a Developer-
# ID-signed binary with an adhoc-signed one AT THE SAME IDENTIFIER,
# silently invalidating the user's release-binary TCC grant on the next
# Claude Desktop restart.

set -euo pipefail

cd "$(dirname "$0")/.."

# ─── Configuration ──────────────────────────────────────────────────────────

# The only Apple Developer Team ID accepted for non-adhoc signing.
# Auto-detected `Developer ID Application: ...` certs whose parenthesized
# Team ID doesn't match this value will be REJECTED — the script falls
# back to adhoc rather than silently signing with an attacker-planted
# cert. Override at your own risk with EXPECTED_TEAM_ID=... .
EXPECTED_TEAM_ID="${EXPECTED_TEAM_ID:-LQ93LRM9QU}"

# Codesign identifier embedded in the signed binary. TCC keys the FDA
# grant off this. Keep distinct from the release identifier so dev
# rebuilds can't clobber a release install's TCC state.
IDENTIFIER="${IMESSAGE_MCP_IDENTIFIER:-com.local.messages-mcp.dev}"

# Absolute paths to the macOS-system binaries we shell out to. Pinning
# these defends against PATH-shimmed `security` / `codesign` (e.g. a
# malicious npm postinstall planting an attacker binary on $PATH).
SECURITY=/usr/bin/security
CODESIGN=/usr/bin/codesign
AWK=/usr/bin/awk

BIN_SRC="bin/imessage-drafts-mcp"
BIN_DEST="${HOME}/bin/imessage-drafts-mcp"

# ─── Build ──────────────────────────────────────────────────────────────────

echo "› bun build --compile"
bun build src/index.ts --compile --outfile "$BIN_SRC"

echo "› clearing xattrs on build output"
xattr -c "$BIN_SRC"

# ─── Pick signing identity ──────────────────────────────────────────────────
#
# Order of preference:
#   1. $CODESIGN_IDENTITY (explicit override — fully bypasses Team ID check;
#      caller's responsibility).
#   2. First `Developer ID Application: ... (<EXPECTED_TEAM_ID>)` cert in
#      the keychain.
#   3. Adhoc (`-`) with a clear warning that FDA grants don't persist
#      across rebuilds.

SIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  # Match the FULL identity line including the Team ID suffix. This
  # rejects an attacker-planted "Developer ID Application: Victim
  # (FAKEID)" cert because (FAKEID) ≠ (EXPECTED_TEAM_ID).
  SIGN_IDENTITY=$("$SECURITY" find-identity -v -p codesigning 2>/dev/null \
    | "$AWK" -F\" -v team="$EXPECTED_TEAM_ID" \
        '/Developer ID Application/ && $2 ~ "\\("team"\\)$" {print $2; exit}')
fi

if [[ -n "$SIGN_IDENTITY" ]]; then
  # Belt-and-suspenders: re-verify the Team ID embedded in the chosen
  # identity string matches EXPECTED_TEAM_ID. The awk regex above
  # already filters, but a CODESIGN_IDENTITY override skips that filter.
  DETECTED_TEAM=$(echo "$SIGN_IDENTITY" | sed -nE 's/.*\(([A-Z0-9]+)\)$/\1/p')
  if [[ "$DETECTED_TEAM" != "$EXPECTED_TEAM_ID" ]]; then
    echo "✗ signing identity Team ID '$DETECTED_TEAM' ≠ expected '$EXPECTED_TEAM_ID'" >&2
    echo "  Refusing to sign with an unknown identity. Either set" >&2
    echo "  EXPECTED_TEAM_ID=... to acknowledge, or remove the offending" >&2
    echo "  cert from your keychain." >&2
    exit 1
  fi
  echo "› signing with Developer ID: $SIGN_IDENTITY"
  # --options=runtime enables Hardened Runtime: library validation,
  # blocks dyld_insert_libraries, refuses unsigned framework loads.
  "$CODESIGN" --force --sign "$SIGN_IDENTITY" --identifier "$IDENTIFIER" --options=runtime "$BIN_SRC"
else
  echo "› no Developer ID cert from team $EXPECTED_TEAM_ID found; falling back to adhoc"
  echo "  ⚠  FDA grants for adhoc-signed binaries get invalidated on each"
  echo "     rebuild (TCC keys off the binary hash). You'll have to re-grant"
  echo "     FDA after every install. Install a Developer ID Application"
  echo "     cert via Xcode → Settings → Accounts → Manage Certificates"
  echo "     to make the grant stick across rebuilds."
  "$CODESIGN" --force --sign - --identifier "$IDENTIFIER" --options=runtime "$BIN_SRC"
fi

# ─── Install ────────────────────────────────────────────────────────────────

echo "› atomic-mv into $BIN_DEST"
mkdir -p "$(dirname "$BIN_DEST")"
cp "$BIN_SRC" "${BIN_DEST}.new"
xattr -c "${BIN_DEST}.new"
mv "${BIN_DEST}.new" "$BIN_DEST"

# ─── Verify ─────────────────────────────────────────────────────────────────
#
# codesign --verify checks the seal: it walks the bundle / Mach-O, hashes
# every signed component, and compares against the embedded code directory.
# A passing exit code means the binary's contents are intact and match
# the signature. This is the right check; `codesign -dv | grep Authority`
# only checks the cert chain string and not the actual seal integrity.

echo "› verifying signature seal"
if ! "$CODESIGN" --verify --strict --verbose "$BIN_DEST" 2>&1; then
  echo "✗ codesign --verify failed on $BIN_DEST" >&2
  exit 1
fi

# Print human-readable identity for build-log audit. Includes the Team
# ID, which is the value we pinned above.
echo "› identity:"
"$CODESIGN" -dv --verbose=2 "$BIN_DEST" 2>&1 | grep -E "Identifier|Authority|TeamIdentifier" || true

# ─── Smoke test ─────────────────────────────────────────────────────────────

echo "› smoke initialize"
SMOKE_OUTPUT=$(echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"install-smoke","version":"0"}}}' | "$BIN_DEST" 2>&1 | head -1)
if echo "$SMOKE_OUTPUT" | grep -q '"serverInfo"'; then
  echo "  ok"
else
  echo "  FAILED: $SMOKE_OUTPUT" >&2
  exit 1
fi

echo
echo "installed: $BIN_DEST"
echo "Restart Claude Desktop (and any other MCP clients) to pick up the new binary."
