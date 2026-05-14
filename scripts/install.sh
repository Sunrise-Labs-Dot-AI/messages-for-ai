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

echo "› re-signing with stable identifier ($IDENTIFIER)"
codesign --force --sign - --identifier "$IDENTIFIER" "$BIN_SRC"

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
