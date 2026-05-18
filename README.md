# Messages for AI

**AI proposes, you approve.** A safer iMessage MCP for users who don't
want Claude sending messages on their behalf without a human in the loop.

This package — `imessage-drafts-mcp` — is the iMessage transport in the
Messages for AI product family. Sibling MCPs (WhatsApp, Signal, Slack) are
on the roadmap; they will share the same menu bar review surface.

## How this differs from the official Anthropic iMessage plugin

[Anthropic ships an official iMessage plugin](https://github.com/anthropics/claude-plugins-official/tree/main/external_plugins/imessage)
that lets Claude send iMessages directly. It's great if you want
frictionless automation. This project exists for the *other* lane — users
who want AI assistance with a safety gate. Pick the one that matches your
risk tolerance:

Claims below describe Anthropic's plugin as published at the linked commit on 2026-05-18; verify against [their repo](https://github.com/anthropics/claude-plugins-official/tree/main/external_plugins/imessage) if checking later.

| | Anthropic `imessage` plugin | Messages for AI (this project) |
|---|---|---|
| **Send model** | Direct — Claude sends immediately on tool call | Staged (default) — `send_draft` is gated by a `require_approval` toggle that ships ON; sends route through the menu bar's hold-to-fire Send button. Users can disable the toggle in the menu bar footer to allow direct MCP sends. |
| **Approval surface** | macOS Automation TCC prompt on first send only | Menu bar review: hold-to-fire Send / Discard per draft (no in-place edit yet — discard and re-stage instead) |
| **Audit log** | Not present at the linked revision | Every **successful** MCP send appended to `~/.messages-mcp/send-audit.log` with timestamp, recipient handle, and SHA-256 of body. Discards and blocked sends are not currently logged. |
| **UI** | CLI-only | Menu bar surface with thread-context bubbles |
| **Contact resolution** | Raw handles only | Resolves to Contacts names via local sidecar |
| **Transports** | iMessage only | iMessage now; WhatsApp / Signal / Slack on the roadmap (per-transport MCPs sharing one menu bar) |
| **Daily send cap** | Not present at the linked revision | Circuit-breaker default 50/UTC-day, env-configurable via `IMESSAGE_DAILY_SEND_CAP` |
| **Best for** | "Just send the message" automation | "Let me see what Claude wants to say before it goes out" — when the default approval gate is on |

If you want fire-and-forget, use Anthropic's plugin. If you want every
outgoing message to pass through your eye first, use this one.

## What this gives you

- read iMessage threads, messages, and search.
- stage drafts under `~/.messages-mcp/drafts/`.
- approval-gated send of staged drafts via AppleScript automation.
- companion **menu bar app** (`/Applications/Messages for AI.app`) that
  shows pending drafts with hold-to-fire Send / Discard buttons. Turns
  "draft" into a real human-review surface rather than a JSON file on disk.
- contact-name resolution via the menu bar app's Contacts permission —
  agents see and surface real names ("Allegra Heath"), not raw phone numbers.
- Designed for **local MCP clients** (Claude Desktop, Claude Code, Codex
  CLI). No network listener. No cloud component.

## Security

This server gives a local binary three macOS-level privileges (Full Disk
Access, Automation control of Messages.app, optional Open-at-Login). The
trust profile is non-trivial. Read **[SECURITY.md](SECURITY.md)** before
installing — it covers the full threat model, the mitigations in place
(prompt-injection wrapping, minimum staged-age, daily send cap, audit
log, SQL parameterization, etc.), the configuration knobs, and the
recommended user-side practices.

For vulnerability reports: open a GitHub Security Advisory on the repo.

## Why this exists

The agents calling this server run on the same Mac as the Messages data.
A local stdio MCP server is the right shape — no tunnel, no cloud, no
shared secret. The blast radius is "what a process running as you can
already do."

## Tools

| Tool | Purpose |
|---|---|
| `list_threads` | Recent threads (newest first). Requires `since` or `contact_filter`. |
| `get_thread` | Messages in a thread, paginated via `before`. |
| `search_messages` | LIKE-search across `text`. Requires `query` plus `since` or `contact_filter`. |
| `stage_draft` | Write a draft to `~/.messages-mcp/drafts/{uuid}.json`. Resolves recipient name. Does NOT send. |
| `list_drafts` | List staged drafts, newest first. |
| `get_draft` | Read one staged draft. |
| `discard_draft` | Delete a staged draft. |
| `send_draft` | **Destructive.** Send a staged draft via Messages.app. Refuses duplicate sends. (Or send via the menu bar app — see below.) |
| `get_current_time` | UTC + system-local timestamps, for building `since` filters. |
| `health_check` | Diagnose permissions / contact lookup / chat.db access. Run when something silently isn't working. |

Hard guardrails:

- `since` older than 2 years → rejected (no deep-history dumps).
- `query` shorter than 2 chars → rejected.
- All message bodies truncated at ~8 KB with a marker.

---

# Install

Two paths. Pick A unless you're contributing code.

## Option A — Pre-built release (recommended)

The release zip contains signed, Apple-notarized binaries. No Xcode, no
Apple Developer account, no rebuild required. The whole install is ~30
seconds plus three manual permission steps.

```sh
# 1. Download the latest release zip.
curl -L \
  https://github.com/Sunrise-Labs-Dot-AI/messages-for-ai/releases/latest/download/imessage-drafts-mcp.zip \
  -o /tmp/imessage-drafts-mcp.zip

# 2. Unzip and run the installer.
cd /tmp && unzip -q imessage-drafts-mcp.zip
cd imessage-drafts-mcp-v* && bash install.sh
```

The installer copies the binary to `~/bin/imessage-drafts-mcp`, installs the
menu bar app to `/Applications/Messages for AI.app`, refreshes
LaunchServices, smoke-tests the MCP via an `initialize` round-trip, and
prints the manual next steps.

After running it, you need to:

1. **Grant Full Disk Access** to `~/bin/imessage-drafts-mcp` — see
   [Permissions](#permissions) below.
2. **Wire up the MCP client** — see [MCP client config](#mcp-client-config) below.
3. **Launch the menu bar app**:
   ```sh
   open "/Applications/Messages for AI.app"
   ```
   First popover open will trigger the macOS Contacts consent dialog.
   Approve it; the app populates `~/.messages-mcp/contacts-cache.json`,
   which the MCP reads to resolve recipient names.

## Option B — Build from source

For contributors. Requires Bun, Xcode 15+, and an **Apple Developer ID
Application certificate** for full contact-name resolution. Without the
cert, contact lookup gracefully falls back to "raw phone numbers" mode
— the rest of the server works fine.

```sh
git clone https://github.com/Sunrise-Labs-Dot-AI/messages-for-ai.git
cd messages-for-ai
bun install

# Install the MCP binary to ~/bin/imessage-drafts-mcp
bun run install:bin

# Build and install the menu bar app to /Applications/
cd menubar && bash scripts/install.sh
```

Both install scripts auto-detect a Developer ID Application certificate
in your Keychain and use it for signing. If none is found, they fall
back to adhoc signing with a clear warning. To force a hard fail on
missing cert (for CI / release builds), set `CONTACTS_REQUIRE_DEVID=1`.

After rebuilding the MCP binary, **restart any MCP client that has
already spawned the old one** (Claude Desktop, Claude Code, Codex CLI) —
they hold a long-lived stdio subprocess and won't pick up the new binary
until they re-spawn.

### Why Developer ID matters

Modern macOS (Sequoia+) silently blocks `CNContactStore.requestAccess`
for adhoc-signed apps. Without a Developer ID cert, the menu bar app
can't read your Contacts via the framework path. (FDA grants for adhoc
binaries also get invalidated on every rebuild, since TCC keys off the
binary hash.) See `menubar/scripts/messages-for-ai.entitlements` for
the Hardened Runtime entitlements required (`personal-information.
addressbook` + `automation.apple-events`).

---

# Permissions

Three TCC grants involved, each gated differently:

## 1. Full Disk Access (on `~/bin/imessage-drafts-mcp`)

Required to read `~/Library/Messages/chat.db`. There's no programmatic
prompt for FDA — you have to do it manually:

1. Open **System Settings → Privacy & Security → Full Disk Access**.
2. Click **+**.
3. Press **⌘⇧G**, paste `~/bin/imessage-drafts-mcp`, press Enter.
4. Confirm the toggle is **on**.

**Troubleshooting: tools return `authorization denied`.** Run
`health_check` from a Claude Desktop chat — it'll report
which subsystem is failing and the remediation. Common cause: the FDA
grant was for an older binary hash and didn't survive a rebuild. Toggle
the entry off and back on (or remove and re-add). With Developer ID
signing in place (default for both the pre-built release and source
builds with a cert), this stops happening — TCC keys the grant off
the cert identity, which is stable across rebuilds.

## 2. Contacts (on the menu bar app)

Required to resolve recipient handles to names. Prompted natively on
first popover open: *"Messages for AI Would Like to Access Your Contacts."*
Click OK. The app then exports a `~/.messages-mcp/contacts-cache.json`
sidecar that the MCP reads on each `stage_draft` call.

The sidecar uses the same data source Messages.app uses, including
iCloud-synced contacts that may be CloudKit-only and absent from the
on-disk AddressBook SQLite. The sidecar refreshes automatically via
`CNContactStoreDidChangeNotification` whenever you edit a contact.

## 3. Automation (on the MCP client / menu bar app, targeting Messages.app)

Required to actually send a staged draft. Prompted on the first call to
`send_draft`: *"<parent app> wants to control Messages.app."*
Click **OK**; the grant persists.

To revoke later: System Settings → Privacy & Security → Automation →
your parent app → Messages → toggle off.

---

# MCP client config

> ⚠️ MCP client `command` fields vary in whether they expand `~`. Claude
> Desktop and Codex CLI do; some terminals' MCP plugins don't. If a
> client fails to launch the server, replace `~/bin/imessage-drafts-mcp` with
> the absolute path (`echo $HOME/bin/imessage-drafts-mcp`).

**Claude Desktop** — `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "imessages": {
      "command": "~/bin/imessage-drafts-mcp"
    }
  }
}
```

Restart Claude Desktop (Cmd+Q on the Claude menu, then reopen — the MCP
child only spawns on app launch).

**Claude Code** — add to `.mcp.json` in your project, or
`~/.claude/mcp.json` for global:

```json
{
  "mcpServers": {
    "imessages": { "command": "~/bin/imessage-drafts-mcp" }
  }
}
```

**Codex CLI** — `~/.codex/config.toml`:

```toml
[mcp_servers.imessages]
command = "~/bin/imessage-drafts-mcp"
```

(Verify against current Codex docs — config shape may have shifted.)

# Quick smoke test (no client needed)

```sh
cat <<'EOF' | ~/bin/imessage-drafts-mcp 2>/tmp/imessage-drafts-mcp.stderr | tail -1
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_threads","arguments":{"limit":3,"since":"2026-05-06T00:00:00Z"}}}
EOF
```

If FDA is granted you'll see your three most-recent threads. Without
FDA the call returns `{"ok":false,"error":"list_threads failed: authorization denied"}`.

Also useful: `health_check` (via a Claude Desktop chat or
the smoke-test pattern above) reports the full live state of permissions
and contact lookup in one call.

---

# Sending drafts — the trust model

`send_draft({ draft_id })` consumes a draft staged via
`stage_draft` and sends it through Messages.app via AppleScript
automation. The design has four trust layers:

1. **MCP destructive annotation.** The tool advertises `destructiveHint: true`
   and `idempotentHint: false`, so MCP clients should surface a confirmation
   prompt before each call.
2. **Send-only-from-draft.** There's no ad-hoc send. Every send requires a
   `draft_id`, so the draft text is observable in the conversation transcript
   before the destructive tool fires — even if the agent calls
   `stage_draft` and `send_draft` in the same turn.
3. **Sent-state lock.** Once a draft has `sent_at` set, re-calling
   `send_draft` returns an explicit "refusing duplicate send"
   error. An agent looping on retry cannot double-send.
4. **macOS TCC Automation.** AppleScript control of Messages.app is gated
   by a separate TCC service from FDA: "Automation". See
   [Permissions](#permissions) above.

If you ever expose this server over a network transport (HTTP / WebSocket /
tunnel), **remove the send tool from the public surface**. The trust
boundary collapses the moment a non-local caller can invoke it — and the
read tools are useful on their own.

---

# Menu bar app

The MCP server stages drafts as JSON files. The companion app at
`/Applications/Messages for AI.app` is a SwiftUI `MenuBarExtra` that
surfaces pending drafts with hold-to-fire Send / Discard buttons — so
you actually review what an agent wants to send before it goes out,
rather than rubber-stamping a tool call that shows only a draft UUID.

### How it works

- Watches `~/.messages-mcp/drafts` via `DispatchSourceFileSystemObject`,
  so drafts staged by the MCP server appear in the popover within ~100ms.
- Sends through the same AppleScript path the MCP server uses
  (`osascript` + `tell application "Messages"`). The duplication is
  intentional — it avoids inventing IPC to the stdio MCP server.
- On send, atomically updates the same draft JSON with `sent_at` +
  `send_service`. Recently-sent drafts (within the last 24 hours) appear
  in a faded "Recently sent" section as a confirmation breadcrumb.
- **Contacts export**: on launch, the app calls `CNContactStore.
  enumerateContacts` and writes `~/.messages-mcp/contacts-cache.json`
  with canonicalized handle → display name pairs. The MCP reads this
  sidecar on every `stage_draft` call to populate
  `to_handle_name`. The sidecar refreshes on `CNContactStoreDidChange`.
- **Open at Login is on by default.** The app self-registers via
  `SMAppService` the first time it runs. Toggle off via the popover
  footer, or via System Settings → General → Login Items.
- **Race trade-off**: both the MCP `send_draft` tool and the
  menu bar app's Send button check `sent_at` before sending, but a true
  simultaneous click on both isn't atomic — you could double-send. For
  a single-user single-recipient flow this is acceptable; if you ever
  scale this up, add an `flock` on the draft file in both code paths.

---

# Tests

```sh
bun test
```

104 tests, ~100ms — pure-function + in-memory SQL + sidecar reader.
Coverage highlights:

- `decode.test.ts` — attributedBody typedstream decoder (short/long lengths, UTF-8, malformed input).
- `open.test.ts` — Apple-epoch ↔ ISO-8601 round-trips for both nanosecond (High Sierra+) and seconds (legacy) forms.
- `schema.test.ts` — Zod input validation: 2-year deep-history reject, 2-char minimums, handle format, body length cap.
- `storage/drafts.test.ts` — staging, list ordering, mark-sent persistence, symlink-clobber defense, atomic-rename + dir mtime, backward-compat normalization for older drafts.
- `storage/contacts-cache.test.ts` — sidecar JSON read path, malformed-input tolerance, schema-version mismatch detection.
- `chatdb/queries.test.ts` — end-to-end SQL against an in-memory chat.db fixture, covering pagination (strict `before`), contact-name widening, and `attributedBody` decode in search. Uses test seams `_setChatDbForTesting` + `_setContactsForTesting` to inject fixtures.
- `tools/health.test.ts` — `canonHandlePublic` canonicalization + probe block resolution logic.

---

# What this does NOT do

- **iOS.** Apple does not allow third-party access to Messages on iOS.
  There is no workaround short of jailbreaking.
- **Network.** Stdio only. If you ever want a cloud agent to call this,
  wrap the same query + draft code behind a tunnel + bearer secret —
  the data layer stays unchanged.
- **Attachments, tapbacks, reactions.** Reads them as plain message
  rows where they appear; doesn't decode payloads.

---

# Project layout

```
src/
  index.ts                 # stdio MCP bootstrap
  schema.ts                # Zod shapes + shared validators
  tools/
    threads.ts             # list_threads, get_thread
    search.ts              # search_messages
    drafts.ts              # stage/list/get/discard/send drafts
    time.ts                # get_current_time
    health.ts              # health_check
    _result.ts             # shared text-result envelopes
  chatdb/
    open.ts                # bun:sqlite read-only handle, Apple-epoch helpers
    decode.ts              # attributedBody → string + truncation
    contacts.ts            # handle → contact name (sidecar primary, SQLite fallback)
    queries.ts             # all SQL — parameterized
  imessage/
    send.ts                # osascript wrapper for Messages.app send
  storage/
    drafts.ts              # ~/.messages-mcp/drafts CRUD
    contacts-cache.ts      # ~/.messages-mcp/contacts-cache.json reader
menubar/
  Package.swift
  Sources/MessagesForAIMenu/
    App.swift              # @main, MenuBarExtra scene, AppDelegate
    DraftStore.swift       # ObservableObject + FS watcher
    DraftSender.swift      # osascript wrapper
    LoginItemController.swift  # SMAppService open-at-login toggle
    ContactsExporter.swift # CNContactStore → sidecar JSON
    Models/Draft.swift     # Codable; mirrors src/storage/drafts.ts
    Views/
      DraftListView.swift  # Pending + Recently-sent sections
      DraftRowView.swift   # Per-draft Send / Discard
      ContactsPermissionBanner.swift  # Shown when NSContacts not granted
  scripts/
    install.sh             # build → .app bundle → codesign (Developer ID or adhoc)
    messages-for-ai.entitlements  # Hardened Runtime entitlements
scripts/
  install.sh               # rebuild MCP binary → xattr-clear → re-sign → atomic-mv
  install-release.sh       # end-user installer bundled INTO the release zip
  build-release.sh         # maintainer: build + notarize + package release zip
  diagnose-contacts.ts     # standalone diagnostic for "contacts not resolving"
```

---

# Cutting a release (maintainer)

The pre-built release is produced by `scripts/build-release.sh`, which
builds + signs + notarizes both binaries with Apple's notary service and
packages them into a self-contained zip.

### One-time setup

1. Install a **Developer ID Application** certificate (Xcode → Settings
   → Accounts → Manage Certificates → + → Developer ID Application).
2. Generate an app-specific password at https://appleid.apple.com →
   Sign-In and Security → App-Specific Passwords. Label it
   `imessage-drafts-mcp-notarytool`.
3. Store it in your Keychain:
   ```sh
   xcrun notarytool store-credentials imessage-drafts-mcp-notary \
     --apple-id <your-developer-account-email> \
     --team-id <your-team-id> \
     --password <app-specific-password>
   ```

### Cutting a release

```sh
# 1. Tag the commit you want to ship and push.
git tag v0.1.0
git push origin v0.1.0

# 2. Build the release zip. Takes ~5-10 min (notarization round-trip).
bash scripts/build-release.sh v0.1.0
# → produces dist/imessage-drafts-mcp-v0.1.0.zip

# 3. Publish via gh CLI.
gh release create v0.1.0 dist/imessage-drafts-mcp-v0.1.0.zip \
  --title 'imessage-drafts-mcp v0.1.0' \
  --notes 'See CHANGELOG / commit history.'
```

The build script fails loudly if no Developer ID cert is found OR if
notarytool credentials aren't set up — no slow rebuild waste. After
zip is produced, it auto-extracts to a temp dir and runs
`spctl --assess` against the unzipped `.app` to make sure Gatekeeper
will accept it on end-user machines. If that check fails, the script
exits 1 instead of shipping a broken release.

Override the notarytool profile name (e.g. for CI) via
`NOTARY_PROFILE=...`. Override the signing identity via `CODESIGN_IDENTITY=...`.
