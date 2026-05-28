#!/usr/bin/env bash
#
# release.sh <version> — one command to ship a Messages for AI release.
#
# Ships BOTH channels from a single version (lockstep, option A):
#   • the notarized .app  → GitHub Release (.zip + stable-named .dmg)
#   • the Claude Code plugin (skills) → published by the git tag itself;
#     users pull it via `/plugin marketplace update`
#
# What it does, in order:
#   1. Preflight  — clean tree, on main, tag is new, gh authed, signing
#                   identity present. Fails fast with plain-English errors.
#   2. Bump       — scripts/bump-version.sh sets plugin + MCP versions.
#   3. Commit     — "chore: release vX.Y.Z" (so the tag points at the bump).
#   4. Build .app — scripts/build-release.sh (compile, sign, notarize, staple).
#   5. Build .dmg — scripts/build-dmg.sh (drag-to-install, notarized).
#   6. Push       — push the commit + the new tag to origin.
#   7. Publish    — gh release create with the .zip AND Messages-for-AI.dmg.
#
# Usage:
#   bash scripts/release.sh v0.3.4              # full release
#   bash scripts/release.sh v0.3.4 --dry-run    # preflight + plan, no changes
#
# Env overrides:
#   NOTARY_PROFILE   keychain profile name (default: imessage-mcp-notary)
#   RELEASE_BRANCH   branch releases must run from (default: main)
#
# Solo-operator notes: see RELEASE.md for the one-time setup (certs, notary
# profile) and the full runbook.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# ── Args ────────────────────────────────────────────────────────────────
RAW="${1:-}"
DRY_RUN=0
for a in "$@"; do
  [ "$a" = "--dry-run" ] && DRY_RUN=1
done
if [ -z "$RAW" ] || [ "$RAW" = "--dry-run" ]; then
  echo "usage: release.sh <version> [--dry-run]   (e.g. v0.3.4)" >&2
  exit 1
fi

VNUM="${RAW#v}"          # 0.3.4
VTAG="v${VNUM}"          # v0.3.4 — build scripts + git tag use this form
RELEASE_BRANCH="${RELEASE_BRANCH:-main}"
RELEASE_ZIP="dist/messages-for-ai-${VTAG}.zip"
RELEASE_DMG="dist/Messages-for-AI.dmg"

if ! [[ "$VNUM" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
  echo "✗ '$RAW' is not a valid version. Expected like v0.3.4 or v0.3.3.1." >&2
  exit 1
fi

step()  { printf '\n\033[1m▶ %s\033[0m\n' "$1"; }
ok()    { printf '  ✓ %s\n' "$1"; }
die()   { printf '\n\033[31m✗ %s\033[0m\n' "$1" >&2; exit 1; }

# ── 1. Preflight ─────────────────────────────────────────────────────────
step "Preflight checks for $VTAG"

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$CURRENT_BRANCH" = "$RELEASE_BRANCH" ] || \
  die "You're on '$CURRENT_BRANCH'. Releases run from '$RELEASE_BRANCH'. Merge your PRs, switch to $RELEASE_BRANCH, then re-run. (Override: RELEASE_BRANCH=$CURRENT_BRANCH)"
ok "on $RELEASE_BRANCH"

# Gate on TRACKED changes only — the release commit is built from tracked
# state, so staged/modified tracked files are the real hazard. Untracked
# files (leftover artifacts, a stray dir from another branch) are surfaced
# as a warning below but don't block.
[ -z "$(git status --porcelain --untracked-files=no)" ] || \
  die "You have uncommitted changes to tracked files. Commit or stash them first — the release commit must be clean."
ok "no uncommitted tracked changes"

UNTRACKED="$(git status --porcelain --untracked-files=all | grep '^??' || true)"
if [ -n "$UNTRACKED" ]; then
  printf '  \033[33m⚠ untracked files present (not blocking, but worth a look):\033[0m\n'
  echo "$UNTRACKED" | sed 's/^?? /      /'
fi

git fetch origin --quiet || true
if [ -n "$(git rev-list "HEAD..origin/$RELEASE_BRANCH" 2>/dev/null)" ]; then
  die "origin/$RELEASE_BRANCH has commits you don't. Run 'git pull' first so the release is built on top of everything."
fi
ok "up to date with origin/$RELEASE_BRANCH"

if git rev-parse "$VTAG" >/dev/null 2>&1 || git ls-remote --tags origin "$VTAG" | grep -q "$VTAG"; then
  die "Tag $VTAG already exists (locally or on origin). Pick the next version, or delete the tag if this was a mistake."
fi
ok "tag $VTAG is new"

command -v gh >/dev/null || die "GitHub CLI 'gh' not found. Install it: brew install gh"
gh auth status >/dev/null 2>&1 || die "Not logged in to GitHub CLI. Run: gh auth login"
ok "gh authenticated"

if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
  die "No 'Developer ID Application' signing certificate in your keychain. Releases can't be signed without it."
fi
ok "Developer ID signing certificate present"

echo
echo "  Plan:"
echo "    • bump plugin.json + 2 MCP package.json → $VNUM"
echo "    • commit 'chore: release $VTAG'"
echo "    • build + notarize .app  → $RELEASE_ZIP"
echo "    • build + notarize .dmg  → $RELEASE_DMG"
echo "    • push commit + tag $VTAG to origin/$RELEASE_BRANCH"
echo "    • gh release create $VTAG  (uploads .zip + .dmg)"
echo "    • plugin ships automatically with the tag (users: /plugin marketplace update)"

if [ "$DRY_RUN" = "1" ]; then
  echo
  ok "DRY RUN — preflight passed, no changes made. Re-run without --dry-run to ship."
  exit 0
fi

# ── 2-3. Bump + commit ─────────────────────────────────────────────────────
step "Bumping versions"
bash scripts/bump-version.sh "$VNUM"
git add .claude-plugin/plugin.json mcps/imessage-drafts/package.json mcps/whatsapp-drafts/package.json
if git diff --cached --quiet; then
  ok "versions already at $VNUM — nothing to commit"
else
  git commit -m "chore: release $VTAG" >/dev/null
  ok "committed 'chore: release $VTAG'"
fi

# ── 4. Build the .app (compile, sign, notarize, staple) ───────────────────
step "Building + notarizing the .app (this is the slow part — a few minutes)"
bash scripts/build-release.sh "$VTAG"
[ -f "$RELEASE_ZIP" ] || die "Expected $RELEASE_ZIP but it's missing. build-release.sh did not produce the zip."
ok "built $RELEASE_ZIP"

# ── 5. Build the .dmg ──────────────────────────────────────────────────────
step "Building + notarizing the .dmg"
bash scripts/build-dmg.sh "$VTAG"
[ -f "$RELEASE_DMG" ] || die "Expected $RELEASE_DMG but it's missing. build-dmg.sh did not produce the dmg."
ok "built $RELEASE_DMG"

# ── 6. Push commit + tag ───────────────────────────────────────────────────
step "Pushing commit + tag $VTAG"
git tag "$VTAG"
git push origin "$RELEASE_BRANCH"
git push origin "$VTAG"
ok "pushed $RELEASE_BRANCH and tag $VTAG"

# ── 7. Publish the GitHub release (both assets) ───────────────────────────
step "Publishing GitHub Release $VTAG"
gh release create "$VTAG" \
  "$RELEASE_ZIP" \
  "$RELEASE_DMG" \
  --title "Messages for AI $VTAG" \
  --generate-notes
ok "release published"

# ── Done ───────────────────────────────────────────────────────────────────
printf '\n\033[1m✓ Shipped %s\033[0m\n\n' "$VTAG"
echo "  App:    https://github.com/Sunrise-Labs-Dot-AI/messages-for-ai/releases/tag/$VTAG"
echo "          DMG download: https://github.com/Sunrise-Labs-Dot-AI/messages-for-ai/releases/latest/download/Messages-for-AI.dmg"
echo "  Plugin: live with the tag. Users update with:  /plugin marketplace update messages-for-ai"
echo
echo "  Next: edit the release notes on GitHub if you want a human summary,"
echo "        then install the DMG yourself to confirm the update lands cleanly."
