# Releasing Messages for AI

How to ship a new version. Written so you don't have to remember the steps —
the script does the remembering. Read this once; after that it's one command.

## TL;DR

```bash
# 1. Merge any feature PRs into main first (on GitHub).
git checkout main && git pull

# 2. Ship. One command. (Dry-run first if you want to be sure.)
bash scripts/release.sh v0.3.4 --dry-run   # checks everything, changes nothing
bash scripts/release.sh v0.3.4             # the real thing
```

That's it. The app lands on GitHub Releases (DMG + zip), and the plugin/skills
ship with the same git tag. Existing users update each channel through its own
mechanism (below).

---

## The mental model: one version, two channels

Messages for AI ships through **two independent pipes**, both driven by a
single version number:

| Channel | What ships | How users get it |
|---|---|---|
| **The .app** | menubar UI + 4 MCP/daemon binaries, notarized | Download the DMG from GitHub Releases (or, once Sparkle lands, auto-update in-app) |
| **The plugin** | `plugin.json` + `skills/*` (no build, no notarization) | `/plugin marketplace update messages-for-ai` in Claude Code — pulls straight from the git tag |

**"Releasing the plugin" is not a build.** It's just the version bump commit +
tag landing on `main`. The Claude Code plugin marketplace reads the repo
directly. So when `release.sh` pushes the tag, the plugin is already live.

### Where the version number actually lives

- **The .app version** is stamped by `build-release.sh` from its `vX.Y.Z`
  argument straight into `Info.plist` (`CFBundleShortVersionString`). You never
  hand-edit it.
- **Three "soft" files** don't follow that arg automatically, so
  `bump-version.sh` rewrites them: `.claude-plugin/plugin.json` and both
  `mcps/*/package.json`. `release.sh` runs this for you.

The first `release.sh` run normalizes all three to match, so any current drift
(plugin.json is on a different number than the MCPs right now) self-heals.

---

## One-time setup

You only do this once per machine. If `release.sh --dry-run` passes, you're set.

1. **Developer ID Application certificate** in your login keychain. (You already
   have this — it's how every build so far got signed.)
2. **Notary credentials** stored as a keychain profile named
   `imessage-mcp-notary` (legacy name, kept for continuity). Override with the
   `NOTARY_PROFILE` env var if yours differs.
3. **GitHub CLI** authenticated: `gh auth login`.
4. **create-dmg**: `brew install create-dmg` (the dmg script auto-installs it if
   missing).

`release.sh` preflight checks #1, #3, and the tag/branch state, and fails with a
plain-English message if something's off — before it changes anything.

---

## What `release.sh` does, step by step

1. **Preflight** — on `main`, clean working tree, up to date with origin, tag is
   new, `gh` authed, signing cert present. Any failure stops here with no changes.
2. **Bump** — `bump-version.sh` sets the three soft versions.
3. **Commit** — `chore: release vX.Y.Z`, so the tag points at the bump.
4. **Build .app** — `build-release.sh`: compile (Swift + Bun), sign every inner
   binary, notarize, staple, Gatekeeper-verify. The slow part (a few minutes).
5. **Build .dmg** — `build-dmg.sh`: wrap the notarized .app in the drag-to-install
   layout, notarize, staple. Output name is stable (`Messages-for-AI.dmg`) so the
   marketing site's `/releases/latest/download/Messages-for-AI.dmg` link never
   changes.
6. **Push** — commit + tag to origin. (This is the moment the plugin goes live.)
7. **Publish** — `gh release create` uploads **both** the `.zip` and the `.dmg`,
   auto-generating notes from merged PRs. Edit the notes on GitHub afterward if
   you want a human summary.

---

## If something breaks mid-release

- **Notarization crash (SIGBUS / signal 10) after upload.** Known notarytool 1.1.0
  bug — the crash is in its output formatter, *not* a failed submission. The build
  scripts already handle it (recover the UUID from history, poll with `info`).
  See the project README's notarization note.
- **Preflight rejected you.** Read the message — it tells you exactly what to fix
  (wrong branch, dirty tree, existing tag, not logged in). Fix and re-run.
- **Build failed after the version bump committed.** The `chore: release` commit
  is already made but nothing was pushed. Fix the build issue, then re-run
  `release.sh vX.Y.Z` — the bump step is idempotent (sees versions already set,
  skips the commit) and it picks up from there. Nothing was pushed or tagged, so
  there's no public mess to clean up.
- **You need to abandon a release entirely.** If nothing was pushed: `git reset
  --hard origin/main`. If the tag was pushed but you want to pull it:
  `git push origin :vX.Y.Z` and delete the GitHub release in the UI.

---

## Auto-update (Sparkle) — readiness notes

Decision: **full Sparkle silent-update is the target** (option A from the
release-architecture session). It is NOT wired up yet. Before it can work, these
must be true — capture them here so the Sparkle phase starts from a checklist:

1. **`CFBundleVersion` must become a real, monotonically increasing build number.**
   Right now `build-release.sh` hardcodes it to `<string>1</string>`. Sparkle
   compares `CFBundleVersion` to decide whether an update is newer — if it's
   always `1`, Sparkle can't tell releases apart. **This is the #1 blocker.** Fix:
   set it to a monotonic integer at build time (e.g. derived from the version, or
   a CI build counter).
2. **EdDSA update-signing key** — generated once, public half embedded in
   `Info.plist` (`SUPublicEDKey`), private half guarded like the notary creds.
3. **Appcast feed** — `appcast.xml` hosted at a stable URL. The Vercel marketing
   site (`messagesfor.ai`) is the natural home: `messagesfor.ai/appcast.xml`.
4. **Sparkle framework embedded** in the bundle, signed with the same identity,
   with its own entitlements (the bundle's signing flow is delicate — per-Mach-O
   `--identifier`, no `--deep`; Sparkle's XPC services need care here).
5. **`release.sh` extended** — after building the .app, sign the update with the
   EdDSA key and append an `<item>` to the appcast, then deploy the site.

**Good news worth verifying first:** a Sparkle update is a same-Developer-ID
re-sign of the same bundle ID. macOS TCC keys the Full Disk Access grant to the
signing identity (cdhash-tolerant), so a same-identity update should **not** force
users to re-grant FDA — i.e. message reads keep working across an auto-update.
This is the scariest failure mode for *this* app, and it's favorable. **Confirm it
with one real end-to-end update test before trusting it in production** (TCC has
surprised this project before — see the #17 saga in the README).
