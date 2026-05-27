#!/usr/bin/env bash
#
# Rebuild + install all MCP transports into the Messages for AI .app
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
# MCP binaries inside a proper .app bundle. The bundle's CFBundleIdentifier
# (`com.sunriselabs.messages-for-ai` — shared with the menubar app)
# becomes the TCC identity for every inner Mach-O; one FDA grant on the
# .app covers the menubar UI AND all backends.
#
# What this script does (loops over INNER_BINARIES):
#   1. `bun build --compile` produces each binary into bin/.
#   2. xattr -cr clears provenance + quarantine flags.
#   3. codesign --force re-signs each binary with --identifier
#      `com.sunriselabs.messages-for-ai` (same as the bundle, so TCC's
#      grant on the .app covers every inner process).
#   4. Atomic-mv each into /Applications/Messages for AI.app/Contents/MacOS/.
#   5. codesign --force (NO --deep) re-seals the .app bundle so the seal
#      covers the new internal binaries.
#   6. Create/refresh a symlink at ~/bin/imessage-drafts-mcp (legacy v0.1.x
#      compat) pointing into the .app.
#   7. JSON-RPC initialize smoke test confirms each stdio MCP boots.
#      (The WhatsApp daemon is not stdio-RPC; smoke test skipped — it's
#      exercised end-to-end by the menubar at runtime.)
#
# Prerequisite: the menubar .app must already be installed.
# Run `(cd menubar && bash scripts/dev-install.sh)` first.

set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"

# ─── Configuration ──────────────────────────────────────────────────────────

# The only Apple Developer Team ID accepted for non-adhoc signing.
EXPECTED_TEAM_ID="${EXPECTED_TEAM_ID:-LQ93LRM9QU}"

# Codesign identifier embedded in every inner binary. MUST match the
# bundle's CFBundleIdentifier (`com.sunriselabs.messages-for-ai`) — TCC
# checks the running process's codesign Identifier= against the granted
# identifier, NOT the parent bundle's CFBundleIdentifier. If an inner
# binary's identifier differs from the bundle's, a single FDA grant on
# the .app won't cover that binary's child process. macOS's standard
# convention for multi-Mach-O .apps (Xcode, Photoshop, anything with
# helpers in Contents/MacOS/) is for every inner binary to share the
# bundle's identifier — that's what we do here.
#
# Same identifier for dev + release is OK: TCC keys grants by
# (identifier, team-id), tolerant of cdhash changes.
IDENTIFIER="${MESSAGES_MCP_IDENTIFIER:-com.sunriselabs.messages-for-ai}"

# Absolute paths to macOS-system binaries. Defends against PATH-shimmed
# `security` / `codesign` (e.g. a malicious npm postinstall planting an
# attacker binary on $PATH).
SECURITY=/usr/bin/security
CODESIGN=/usr/bin/codesign
AWK=/usr/bin/awk

APP="/Applications/Messages for AI.app"
SYMLINK="${HOME}/bin/imessage-drafts-mcp"
ENTITLEMENTS="$REPO_ROOT/menubar/scripts/messages-for-ai.entitlements"

# Every inner Mach-O the .app ships. Adding a future transport is a new
# entry here plus a build block below.
INNER_BINARIES=(
  "imessage-drafts-mcp"
  "imessage-drafts-daemon"
  "whatsapp-drafts-mcp"
  "whatsapp-drafts-daemon"
)

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

mkdir -p "$REPO_ROOT/bin"

# ─── Build ──────────────────────────────────────────────────────────────────

echo "› building imessage-drafts-mcp + imessage-drafts-daemon"
(
  cd "$REPO_ROOT/mcps/imessage-drafts"
  bun install >/dev/null
  bun build src/index.ts --compile --outfile "$REPO_ROOT/bin/imessage-drafts-mcp"
  # The daemon performs the FDA-gated chat.db reads when launched by the
  # menu-bar app (which holds the grant). bun:sqlite compiles in natively —
  # no --external needed (unlike the WhatsApp daemon's native modules).
  bun build src/daemon/index.ts --compile --outfile "$REPO_ROOT/bin/imessage-drafts-daemon"
)

echo "› building whatsapp-drafts-mcp + whatsapp-drafts-daemon"
(
  cd "$REPO_ROOT/mcps/whatsapp-drafts"
  bun install --frozen-lockfile >/dev/null
  bun build src/index.ts --compile --outfile "$REPO_ROOT/bin/whatsapp-drafts-mcp"
  # Native/heavy modules don't compile-bundle cleanly; pulled from
  # node_modules at runtime via the daemon's resolver.
  bun build src/daemon/index.ts --compile \
    --outfile "$REPO_ROOT/bin/whatsapp-drafts-daemon" \
    --external jimp --external sharp \
    --external link-preview-js --external audio-decode
)

for inner in "${INNER_BINARIES[@]}"; do
  xattr -c "$REPO_ROOT/bin/$inner"
done

# ─── Sign each binary with the bundle's identifier ──────────────────────────

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
  echo "› signing binaries with Developer ID: $SIGN_IDENTITY"
  for inner in "${INNER_BINARIES[@]}"; do
    "$CODESIGN" --force --sign "$SIGN_IDENTITY" \
      --identifier "$IDENTIFIER" --options=runtime \
      --entitlements "$ENTITLEMENTS" \
      "$REPO_ROOT/bin/$inner"
  done
else
  echo "› no Developer ID cert from team $EXPECTED_TEAM_ID found; falling back to adhoc"
  echo "  ⚠  FDA grants for adhoc-signed bundles are unstable across rebuilds."
  for inner in "${INNER_BINARIES[@]}"; do
    "$CODESIGN" --force --sign - \
      --identifier "$IDENTIFIER" --options=runtime \
      --entitlements "$ENTITLEMENTS" \
      "$REPO_ROOT/bin/$inner"
  done
fi

# ─── Install into the .app bundle ───────────────────────────────────────────

for inner in "${INNER_BINARIES[@]}"; do
  dest="$APP/Contents/MacOS/$inner"
  echo "› installing $dest"
  cp "$REPO_ROOT/bin/$inner" "${dest}.new"
  xattr -c "${dest}.new"
  mv "${dest}.new" "$dest"
done

# ─── Re-seal the .app bundle ────────────────────────────────────────────────
#
# Re-signs the bundle at its root, updating the seal to cover every
# replaced inner binary. We DELIBERATELY DO NOT pass --deep here, because
# --deep walks every inner Mach-O and re-derives each one's identifier
# from its path basename — which clobbers the explicit `--identifier
# "$IDENTIFIER"` we set above. That would leave each inner binary with
# an identity TCC can't match against any FDA grant. Discovered the hard
# way in v0.2.0 development.

if [[ -n "$SIGN_IDENTITY" ]]; then
  echo "› re-sealing .app bundle with Developer ID: $SIGN_IDENTITY"
  "$CODESIGN" --force --sign "$SIGN_IDENTITY" \
    --identifier "$IDENTIFIER" --options=runtime \
    --entitlements "$ENTITLEMENTS" "$APP"
else
  echo "› re-sealing .app bundle adhoc"
  "$CODESIGN" --force --sign - \
    --identifier "$IDENTIFIER" --options=runtime "$APP"
fi

# ─── Verify the bundle seal ─────────────────────────────────────────────────

echo "› verifying .app signature seal"
if ! "$CODESIGN" --verify --strict --verbose "$APP" 2>&1; then
  echo "✗ codesign --verify failed on $APP" >&2
  exit 1
fi

# Defensive post-seal check: confirm every inner binary's Identifier=
# survived the bundle re-seal. If a future edit reintroduces --deep,
# this trips and we fail loudly BEFORE the smoke test.
for inner in "${INNER_BINARIES[@]}"; do
  app_bin="$APP/Contents/MacOS/$inner"
  GOT_IDENT=$("$CODESIGN" -dv --verbose=2 "$app_bin" 2>&1 \
    | sed -nE 's/^Identifier=(.*)$/\1/p' | head -1)
  if [[ "$GOT_IDENT" != "$IDENTIFIER" ]]; then
    echo "✗ $app_bin reports Identifier='$GOT_IDENT', expected '$IDENTIFIER'." >&2
    echo "  TCC's FDA grant on the .app won't cover this binary's process." >&2
    echo "  Likely cause: --deep was reintroduced on the bundle re-seal step." >&2
    exit 1
  fi
done
echo "› all inner binaries verified: Identifier=$IDENTIFIER (matches bundle)"

# ─── Maintain ~/bin/ symlink for backward compat ────────────────────────────
#
# MCP client configs that point at ~/bin/imessage-drafts-mcp (the v0.1.x
# convention) keep working — the symlink resolves to the .app-internal
# binary at exec time. TCC sees the binary's actual path inside the .app
# and applies the bundle's grant.

echo "› maintaining symlink: $SYMLINK → $APP/Contents/MacOS/imessage-drafts-mcp"
mkdir -p "$(dirname "$SYMLINK")"
ln -sf "$APP/Contents/MacOS/imessage-drafts-mcp" "$SYMLINK"

# ─── Smoke test (stdio MCPs only) ───────────────────────────────────────────

smoke_stdio_mcp() {
  local label="$1"
  local bin="$2"
  echo "› smoke initialize: $label"
  local stderr_log
  stderr_log=$(mktemp)
  trap 'rm -f "${stderr_log:-}"' RETURN
  local out
  out=$(echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"install-smoke","version":"0"}}}' \
    | "$bin" 2>"$stderr_log" | head -1)
  if echo "$out" | grep -q '"serverInfo"'; then
    echo "  ok"
    rm -f "$stderr_log"
    return 0
  fi
  echo "  FAILED — $label stdout: $out" >&2
  echo "  FAILED — $label stderr:" >&2
  cat "$stderr_log" >&2
  rm -f "$stderr_log"
  return 1
}

smoke_stdio_mcp "imessage-drafts-mcp" "$APP/Contents/MacOS/imessage-drafts-mcp"
smoke_stdio_mcp "whatsapp-drafts-mcp" "$APP/Contents/MacOS/whatsapp-drafts-mcp"

# whatsapp-drafts-daemon is not stdio-RPC; its lifecycle is exercised
# end-to-end by the menubar's WhatsAppDaemonController.

echo
echo "installed: ${INNER_BINARIES[*]} → $APP/Contents/MacOS/"
echo "           $SYMLINK → imessage-drafts-mcp (legacy v0.1.x path)"
echo
echo "MCP client configs can point at EITHER the symlink or the .app-internal"
echo "binary paths. Both resolve to the same Mach-O, which inherits FDA from"
echo "the .app bundle's TCC identity."
echo
echo "Restart Claude Desktop (and any other MCP clients) to pick up the new"
echo "binaries. The WhatsApp daemon is spawned by the menubar on demand."
