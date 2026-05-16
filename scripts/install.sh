#!/usr/bin/env bash
#
# Rebuild + install imessage-mcp into ~/bin with the macOS dance that lets
# repeated rebuilds keep launching:
#
#   1. Build via `bun build --compile`.
#   2. Clear extended attributes (provenance + quarantine flags can otherwise
#      flag the binary as untrusted on next launch).
#   3. Re-sign with `codesign --force --sign -` and a STABLE identifier
#      (default: com.local.imessage-mcp; override via env var
#      IMESSAGE_MCP_IDENTIFIER). bun's default linker-signed identifier
#      is `a.out`, which macOS treats inconsistently when overwriting an
#      existing binary at the same path. A stable identifier also means
#      the macOS Full Disk Access grant survives rebuilds — TCC keys
#      the grant off the identifier, not the per-build hash.
#   4. Atomic-mv into place (rather than `cp` overwriting in-place; the latter
#      can trigger `kernel: load code signature error 2` on the next exec).
#
# After running this, restart any MCP clients that have already spawned the
# old binary (Claude Desktop, Claude Code, Codex CLI) — they need to fork
# a fresh subprocess.

set -euo pipefail

cd "$(dirname "$0")/.."

BIN_SRC="bin/imessage-mcp"
BIN_DEST="${HOME}/bin/imessage-mcp"
IDENTIFIER="${IMESSAGE_MCP_IDENTIFIER:-com.local.imessage-mcp}"

echo "› bun build --compile"
bun build src/index.ts --compile --outfile "$BIN_SRC"

echo "› clearing xattrs on build output"
xattr -c "$BIN_SRC"

# Pick a codesigning identity. Same logic as menubar/scripts/install.sh.
# Order of preference:
#   1. $CODESIGN_IDENTITY (explicit override).
#   2. First "Developer ID Application: …" cert in the user's keychain.
#   3. Adhoc (`-`).
#
# Why this matters: TCC keys the Full Disk Access grant off the
# codesigning identity. For adhoc-signed binaries that means the
# binary's CDHash — which changes on every rebuild — so each rebuild
# silently invalidates the FDA grant and the user has to re-toggle
# the entry in System Settings → Privacy & Security → Full Disk
# Access. A real Developer ID cert has a stable identity (cert
# fingerprint), so the grant survives rebuilds.
SIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F\" '/Developer ID Application/ {print $2; exit}')
fi

if [[ -n "$SIGN_IDENTITY" ]]; then
  echo "› signing with Developer ID: $SIGN_IDENTITY"
  # --options=runtime enables Hardened Runtime: macOS enforces
  # library validation, blocks dyld_insert_libraries, refuses unsigned
  # framework loads, etc. Required for Developer ID signed binaries
  # to behave well with TCC on modern macOS.
  codesign --force --sign "$SIGN_IDENTITY" --identifier "$IDENTIFIER" --options=runtime "$BIN_SRC"
else
  echo "› no Developer ID cert found; falling back to adhoc"
  echo "  ⚠  FDA grants for adhoc-signed binaries get invalidated on each"
  echo "     rebuild (TCC keys off the binary hash). You'll have to re-grant"
  echo "     FDA after every install. Install a Developer ID Application"
  echo "     cert via Xcode → Settings → Accounts → Manage Certificates"
  echo "     to make the grant stick across rebuilds."
  codesign --force --sign - --identifier "$IDENTIFIER" --options=runtime "$BIN_SRC"
fi

echo "› atomic-mv into $BIN_DEST"
mkdir -p "$(dirname "$BIN_DEST")"
cp "$BIN_SRC" "${BIN_DEST}.new"
xattr -c "${BIN_DEST}.new"
mv "${BIN_DEST}.new" "$BIN_DEST"

echo "› verifying signature"
codesign -dv "$BIN_DEST" 2>&1 | grep -E "Identifier|Signature" || true

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
