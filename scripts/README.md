# scripts/

Three scripts live here. They have **different audiences** and run in
**different contexts**. The naming is deliberate — there is no plain
`install.sh` in the repo so that a contributor can't run the wrong one
by reflex.

## Architecture: the `.app`-wrap layout

Both the menubar UI binary (`MessagesForAIMenu`) and the MCP binary
(`imessage-drafts-mcp`) live inside one `.app` bundle:

```
/Applications/Messages for AI.app/
└── Contents/
    ├── Info.plist           (CFBundleIdentifier = com.sunriselabs.messages-for-ai)
    └── MacOS/
        ├── MessagesForAIMenu        (Swift menubar UI — Info.plist's CFBundleExecutable)
        └── imessage-drafts-mcp      (compiled Bun MCP binary — sidecar)
```

A backward-compat symlink at `~/bin/imessage-drafts-mcp` →
`/Applications/Messages for AI.app/Contents/MacOS/imessage-drafts-mcp`
lets MCP client configs that hard-coded `~/bin/imessage-drafts-mcp`
keep working.

**Why both inner binaries share `Identifier=com.sunriselabs.messages-for-ai`:**
macOS TCC keys Full Disk Access grants by the running process's
codesign `Identifier=` string (compared against the granted bundle ID
in TCC.db). When you drag a Mach-O that lives inside an `.app` into
System Settings → FDA, macOS resolves up and stores the grant against
the bundle's `CFBundleIdentifier`. For the inner MCP binary's process
to be covered by that grant, its `Identifier=` must equal the bundle's
identifier — not a separate per-binary string. This is also how
Apple's own multi-Mach-O bundles work (Xcode, Photoshop, anything with
sidecar binaries in `Contents/MacOS/`).

⚠️ **Never run `codesign --deep` on the bundle after you've signed
inner binaries with explicit `--identifier`.** `--deep` re-derives
each inner Mach-O's identifier from its path basename and clobbers
the explicit value. The bundle's seal will still verify; the .app
will launch; the MCP will fail to read chat.db at runtime with
`permission_denied` because TCC can't match the path-derived
identifier against any FDA grant. `dev-install.sh` and
`build-release.sh` both guard against this — `build-release.sh`
has a defensive post-seal check that fails the build if either inner
binary's identifier ≠ `com.sunriselabs.messages-for-ai`.

## `dev-install.sh` — contributor / local development

Rebuilds the MCP binary from source via `bun build --compile`,
codesigns it with the contributor's
`Developer ID Application: ... (LQ93LRM9QU)` cert (auto-detected;
falls back to adhoc with a warning), installs it INTO the existing
`/Applications/Messages for AI.app/Contents/MacOS/`, then re-seals
the bundle (without `--deep`).

Run this when:
- You've made a code change to `src/` and want to test it against your
  live Claude Desktop / Claude Code MCP client.
- You're iterating on the MCP server itself.

**Prerequisite:** the menubar `.app` must already exist at
`/Applications/Messages for AI.app/`. If it doesn't, install it first:

```sh
cd menubar && bash scripts/dev-install.sh
```

Then from the repo root:

```sh
bun run install:bin    # or: bash scripts/dev-install.sh
```

Identifier embedded in the signed inner binary:
**`com.sunriselabs.messages-for-ai`** (same as the bundle). Same
identifier in both dev and release builds — TCC's grant matches on
`(identifier, team-id)` and is tolerant of cdhash changes, so a dev
rebuild updates the cdhash but doesn't invalidate any existing FDA
grant on the bundle.

## `build-release.sh` — maintainer

Builds + signs + notarizes ONE `.app` bundle containing BOTH binaries,
packages it (plus a copy of `install-release.sh` renamed to
`install.sh`, plus a short user-facing README) into
`dist/imessage-drafts-mcp-<version>.zip`, ready for upload to GitHub
Releases.

Single notary submission for the bundle (the bundle's seal covers
both inner binaries — no separate binary submission needed).

Run this when cutting a tagged release. One-time setup required:

```sh
xcrun notarytool store-credentials imessage-drafts-mcp-notary \
  --apple-id <your-apple-id> \
  --team-id LQ93LRM9QU \
  --password <app-specific-password-from-appleid.apple.com>
```

Then:

```sh
bash scripts/build-release.sh v0.2.0
gh release create v0.2.0 dist/imessage-drafts-mcp-v0.2.0.zip ...
```

Takes ~5–10 minutes (most of which is Apple's notarization queue).

Identifier embedded in BOTH inner binaries and the bundle:
**`com.sunriselabs.messages-for-ai`**.

## `install-release.sh` — end user

Does NOT compile anything. Copies the pre-built, already-signed-and-
notarized `.app` from a release zip into `/Applications/`, creates the
`~/bin/imessage-drafts-mcp` backward-compat symlink, removes legacy
v0.1.x install artifacts (`~/bin/imessage-mcp`, `~/Applications/...`).

This script ships *inside* the release zip (where `build-release.sh`
renames it to plain `install.sh` because that's the universal naming
convention end users expect). End users do NOT run it from the repo —
they download the release zip, unzip, and run the bundled `install.sh`.

Lives in the repo so contributors can audit and modify what the
end-user install does.

Before copying anything, this script verifies:
1. The bundle's embedded `TeamIdentifier` matches `LQ93LRM9QU`. Refuses
   to install otherwise — defends against phishing-site forged releases
   signed under an attacker's Developer ID.
2. The inner MCP binary's `TeamIdentifier` also matches (catches a
   release zip with a stale or unsigned inner binary).
3. `codesign --verify --strict` passes on the .app.
4. `spctl --assess` accepts the .app (i.e. Apple's notarization is
   recognized).

Override `EXPECTED_TEAM_ID=...` if you're intentionally installing a
fork's release.

## Menu bar app entitlements

The signed menu bar app embeds `menubar/scripts/messages-for-ai.entitlements`.
It declares **`com.apple.security.automation.apple-events: true`** (required
for hardened-runtime non-sandboxed apps to send any Apple Event at all —
removing it would block the AppleScript path the app uses to talk to
Messages.app) and **`com.apple.security.scripting-targets`** scoped to
`com.apple.iChat` (the historical bundle ID Messages.app still ships with).

⚠️ The `scripting-targets` entry is **not enforced** by the OS for
non-sandboxed apps — it documents intent but doesn't bound the Apple
Events scope at runtime. Real enforcement requires turning the menubar
into a sandboxed app with `com.apple.security.app-sandbox`, which needs
temporary-exception entries for `~/.messages-mcp/` filesystem access.
That's a deferred refactor (v0.1.2). The full reasoning lives in the
XML comment at the top of the entitlement file. A reviewer auditing
Apple-events exposure should read both this section AND that comment.

## `diagnose-contacts.ts`

Not an installer — a standalone diagnostic that runs the contact-
resolution code paths against the local Contacts.app data and prints
what would happen. Useful when `to_handle_name` resolution is silently
failing and you want to know which DB the loader picked, whether the
sidecar is being honored, etc.

```sh
bun scripts/diagnose-contacts.ts
```
