# scripts/

Three scripts live here. They have **different audiences** and run in
**different contexts**. The naming is deliberate — there is no plain
`install.sh` in the repo so that a contributor can't run the wrong one
by reflex.

## `dev-install.sh` — contributor / local development

Builds the MCP binary from source via `bun build --compile`, codesigns
it with the contributor's `Developer ID Application: ... (LQ93LRM9QU)`
cert (auto-detected; falls back to adhoc with a warning), and installs
it to `~/bin/imessage-drafts-mcp`.

Run this when:
- You've made a code change to `src/` and want to test it against your
  live Claude Desktop / Claude Code MCP client.
- You're iterating on the MCP server itself.

```sh
bun run install:bin    # or: bash scripts/dev-install.sh
```

Identifier embedded in the signed binary: **`com.local.messages-mcp.dev`**.
Distinct from the release identifier so dev rebuilds can't clobber a
release install's TCC grant. See the comment at the top of the script
for the full reasoning.

## `build-release.sh` — maintainer

Builds + signs + notarizes the MCP binary AND the menu bar app, packages
everything (plus a copy of `install-release.sh` renamed to `install.sh`,
plus a short user-facing README) into `dist/imessage-drafts-mcp-<version>.zip`,
ready for upload to GitHub Releases.

Run this when cutting a tagged release. One-time setup required:

```sh
xcrun notarytool store-credentials imessage-drafts-mcp-notary \
  --apple-id <your-apple-id> \
  --team-id LQ93LRM9QU \
  --password <app-specific-password-from-appleid.apple.com>
```

Then:

```sh
bash scripts/build-release.sh v0.1.1
gh release create v0.1.1 dist/imessage-drafts-mcp-v0.1.1.zip ...
```

Takes ~5–10 minutes (most of which is Apple's notarization queue).

Identifier embedded in the release binary: **`com.sunriselabs.messages-mcp`**.
The menu bar app's bundle ID is **`com.sunriselabs.messages-for-ai`**.

## `install-release.sh` — end user

Does NOT compile anything. Copies the pre-built, already-signed-and-
notarized artifacts from a release zip into the conventional locations.

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
2. `codesign --verify --strict` passes on both the binary and the .app.
3. `spctl --assess` accepts the .app (i.e. Apple's notarization is
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
