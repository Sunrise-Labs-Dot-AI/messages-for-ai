# imessage-mcp

A local MCP server that exposes read-only access to your macOS iMessages
(`~/Library/Messages/chat.db`) and lets agents stage outgoing drafts as
local JSON files. **Drafts never auto-send.**

- read iMessage threads, messages, and search.
- stage drafts under `~/.imessage-mcp/drafts/`.
- approval-gated send of staged drafts via AppleScript automation.
- companion **menu bar app** (`menubar/`) that shows pending drafts
  with Send / Discard buttons. Turns "draft" into a real human-review
  surface rather than a JSON file on disk.
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
| `list_imessage_threads` | Recent threads (newest first). Requires `since` or `contact_filter`. |
| `get_imessage_thread` | Messages in a thread, paginated via `before`. |
| `search_imessages` | LIKE-search across `text`. Requires `query` plus `since` or `contact_filter`. |
| `stage_imessage_draft` | Write a draft to `~/.imessage-mcp/drafts/{uuid}.json`. Does NOT send. |
| `list_imessage_drafts` | List staged drafts, newest first. |
| `get_imessage_draft` | Read one staged draft. |
| `discard_imessage_draft` | Delete a staged draft. |
| `send_imessage_draft` | **Destructive.** Send a staged draft via Messages.app. Refuses duplicate sends. (Or send via the menu bar app — see below.) |
| `get_imessage_current_time` | UTC + system-local timestamps, for building `since` filters. |

Hard guardrails:

- `since` older than 2 years → rejected (no deep-history dumps).
- `query` shorter than 2 chars → rejected.
- All message bodies truncated at ~8 KB with a marker.

## One-time setup

### 1. Build + install

```sh
git clone https://github.com/Sunrise-Labs-Dot-AI/imessage-mcp.git
cd imessage-mcp
bun install
bun run install:bin
# → builds bin/imessage-mcp, clears xattrs, re-signs with a stable identifier
#   (com.local.imessage-mcp), atomic-moves to ~/bin/imessage-mcp,
#   smoke-tests an initialize call.
```

The MCP clients all spawn this exact binary path, so installing it to
`~/bin/` decouples it from the build directory.

The `install:bin` script (in `scripts/install.sh`) is doing macOS housekeeping
that a plain `cp` skips: bun's `--compile` produces an `adhoc,linker-signed`
binary whose code hash changes on every rebuild. If you `cp` it over an
existing binary at the same path, macOS may kill the next exec with
`kernel: load code signature error 2`. Re-signing with `--force` + a stable
identifier and atomic-mv avoids that whole class of failure.

After rebuilding, **restart any MCP client that has already spawned the
old binary** (Claude Desktop, Claude Code, Codex CLI) — they hold a long-
lived stdio subprocess and won't pick up the new binary until they
re-spawn.

### 3. Grant Full Disk Access

`chat.db` and the Contacts database are protected by macOS TCC. The
binary needs Full Disk Access to read them.

1. Open **System Settings → Privacy & Security → Full Disk Access**.
2. Click **+**.
3. Press **⌘⇧G**, paste `~/bin/imessage-mcp`, press Enter.
4. Confirm the toggle is **on**.

(Granting FDA to the binary itself — not to Claude/Codex/Terminal — is
the tight option: only this one program gets the privilege, not every
tool the parent spawns. The stable codesign identifier
`com.local.imessage-mcp` set by `scripts/install.sh` means TCC
keys the grant off the identifier, so rebuilds *usually* survive.)

**Troubleshooting: tools return `authorization denied`.** TCC grants
sometimes decay — macOS updates, Claude.app updates, or just luck.
Symptom: every chat.db-touching tool fails (`list_imessage_threads`,
the context-lookup inside `stage_imessage_draft`, etc.), and the
`context_diagnostic` field on freshly-staged drafts reports
`error: authorization denied`. Fix: in System Settings → Privacy &
Security → Full Disk Access, toggle the `imessage-mcp` entry **off
and back on** (or remove it via `−` and re-add via `+`). The next
chat.db-touching call from an already-running MCP client picks the
grant up — no client restart needed. (`openChatDb()` retries the
SQLite open on every call until it succeeds, so the cached-failure
case doesn't apply.) Client restart is only required if you've
replaced the binary itself (via `bun run install:bin`).

### 4. Wire up the MCP clients

> ⚠️ MCP client `command` fields vary in whether they expand `~`. Claude
> Desktop and Codex CLI do; some terminals' MCP plugins don't. If a
> client fails to launch the server, replace `~/bin/imessage-mcp` with
> the absolute path (`echo $HOME/bin/imessage-mcp`).

**Claude Desktop** — `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "imessages": {
      "command": "~/bin/imessage-mcp"
    }
  }
}
```

Restart Claude Desktop.

**Claude Code** — add to `.mcp.json` in your project, or
`~/.claude/mcp.json` for global:

```json
{
  "mcpServers": {
    "imessages": { "command": "~/bin/imessage-mcp" }
  }
}
```

**Codex CLI** — `~/.codex/config.toml`:

```toml
[mcp_servers.imessages]
command = "~/bin/imessage-mcp"
```

(Verify against current Codex docs — config shape may have shifted.)

## Quick smoke test (no client needed)

```sh
cat <<'EOF' | ~/bin/imessage-mcp 2>/tmp/imessage-mcp.stderr | tail -1
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_imessage_threads","arguments":{"limit":3,"since":"2026-05-06T00:00:00Z"}}}
EOF
```

If FDA is granted you'll see your three most-recent threads. Without
FDA the call returns `{"ok":false,"error":"list_imessage_threads failed: authorization denied"}`.

## Sending drafts (P2)

`send_imessage_draft({ draft_id })` consumes a draft staged via
`stage_imessage_draft` and sends it through Messages.app via AppleScript
automation. The design has four trust layers:

1. **MCP destructive annotation.** The tool advertises `destructiveHint: true`
   and `idempotentHint: false`, so MCP clients should surface a confirmation
   prompt before each call.
2. **Send-only-from-draft.** There's no ad-hoc send. Every send requires a
   `draft_id`, so the draft text is observable in the conversation transcript
   before the destructive tool fires — even if the agent calls
   `stage_imessage_draft` and `send_imessage_draft` in the same turn.
3. **Sent-state lock.** Once a draft has `sent_at` set, re-calling
   `send_imessage_draft` returns an explicit "refusing duplicate send"
   error. An agent looping on retry cannot double-send.
4. **macOS TCC Automation.** AppleScript control of Messages.app is gated
   by a separate TCC service from FDA: "Automation". The first send triggers
   a system prompt of the form *"<parent app> wants to control Messages.app.
   This will provide access to documents and data in Messages."* Approve it
   once; the grant persists.

If you ever expose this server over a network transport (HTTP / WebSocket /
tunnel), **remove the send tool from the public surface**. The trust
boundary collapses the moment a non-local caller can invoke it — and the
read tools are useful on their own.

### One-time Automation permission

The first time a parent app sends a draft, macOS will pop up:

> "<parent app>.app" wants access to control "Messages.app". Allowing
> control will provide access to documents and data in "Messages.app", and
> to perform actions within that app.

Click **OK**. To revoke later: System Settings → Privacy & Security →
Automation → (your parent app) → Messages → toggle off.

## Re-deploying after edits

```sh
bun test           # 54 tests, ~200ms — pure-function + in-memory SQL
bun run install:bin
```

After this, **restart Claude Desktop** (and any other MCP client) so the
client picks up the new binary on its next stdio spawn.

## Menu bar app (P3)

The MCP server stages drafts as JSON files. The companion app at
`menubar/` is a SwiftUI `MenuBarExtra` that surfaces pending drafts with
Send / Discard buttons — so you actually review what an agent wants to
send before it goes out, rather than rubber-stamping a tool call that
shows only a draft UUID.

### Build + install

```sh
cd menubar
bash scripts/install.sh
# → produces /Applications/iMessage Drafts.app
```

Requires Swift 5.9+ (Xcode 15 / macOS 14+ ships it). The script wraps the
SPM-built executable in a proper `.app` bundle with `LSUIElement = true`
so it lives in the menu bar with no Dock icon, and code-signs it with a
stable bundle ID so the macOS Automation grant survives rebuilds.

The default install root is `/Applications`. On a default macOS setup the
local admin user can write there without sudo. If `/Applications` is
locked down (managed Mac, restricted account), set `INSTALL_ROOT` to
override:

```sh
INSTALL_ROOT="$HOME/Applications" bash scripts/install.sh
```

Then:

```sh
open "/Applications/iMessage Drafts.app"
```

…or just open Finder → Applications and double-click the app.

The first Send will trigger a macOS Automation prompt — "iMessage Drafts
wants to control Messages" — click OK.

**Open at Login is on by default.** The app self-registers via
`SMAppService` the first time it runs. Toggle it off via the popover
footer, or via System Settings → General → Login Items.

### How it works

- Watches `~/.imessage-mcp/drafts` via `DispatchSourceFileSystemObject`,
  so drafts staged by the MCP server appear in the popover within
  ~100ms.
- Sends through the same AppleScript path the MCP server uses
  (`osascript` + `tell application "Messages"`). The duplication is
  intentional — it avoids inventing IPC to the stdio MCP server.
- On send, atomically updates the same draft JSON with `sent_at` +
  `send_service`. Recently-sent drafts (within the last hour) appear in
  a faded "Recently sent" section as a confirmation breadcrumb.
- **Race trade-off**: both the MCP `send_imessage_draft` tool and the
  menu bar app's Send button check `sent_at` before sending, but a true
  simultaneous click on both isn't atomic — you could double-send. For
  a single-user single-recipient flow this is acceptable; if you ever
  scale this up, add an `flock` on the draft file in both code paths.

### Project layout

```
menubar/
  Package.swift
  Sources/iMessageDraftsMenu/
    App.swift              # @main, MenuBarExtra scene, AppDelegate
    DraftStore.swift       # ObservableObject + FS watcher
    DraftSender.swift      # osascript wrapper
    LoginItemController.swift  # SMAppService open-at-login toggle
    Models/Draft.swift     # Codable; mirrors src/storage/drafts.ts
    Views/
      DraftListView.swift  # Pending + Recently-sent sections
      DraftRowView.swift   # Per-draft Send / Discard
  scripts/install.sh       # build → .app bundle → codesign
```

## Tests

```sh
bun test
```

Coverage:

- `decode.test.ts` — attributedBody typedstream decoder (short/long lengths, UTF-8, malformed input).
- `open.test.ts` — Apple-epoch ↔ ISO-8601 round-trips for both nanosecond (High Sierra+) and seconds (legacy) forms.
- `schema.test.ts` — Zod input validation: 2-year deep-history reject, 2-char minimums, handle format, body length cap.
- `storage/drafts.test.ts` — staging, list ordering, mark-sent persistence, backward-compat normalization for drafts written before `sent_at` existed.
- `chatdb/queries.test.ts` — end-to-end SQL against an in-memory chat.db fixture, covering pagination (strict `before`), the Catesby contact-name widening, and `attributedBody` decode in search. Uses test seams `_setChatDbForTesting` + `_setContactsForTesting` to inject fixtures.

## What this does NOT do

- **iOS.** Apple does not allow third-party access to Messages on iOS.
  There is no workaround short of jailbreaking.
- **Network.** Stdio only. If you ever want the cloud PA / Managed
  Agents to call this, wrap the same query + draft code behind a
  Cloudflare Tunnel + bearer secret — the data layer stays unchanged.
- **Attachments, tapbacks, reactions.** Reads them as plain message
  rows where they appear; doesn't decode payloads.

## Layout

```
src/
  index.ts                 # stdio MCP bootstrap
  schema.ts                # Zod shapes + shared validators
  tools/                   # MCP tool registrations (one file per domain)
    threads.ts             # list_imessage_threads, get_imessage_thread
    search.ts              # search_imessages
    drafts.ts              # stage/list/get/discard/send drafts
    time.ts                # get_imessage_current_time
    _result.ts             # shared text-result envelopes
  chatdb/
    open.ts                # bun:sqlite read-only handle, Apple-epoch helpers
    decode.ts              # attributedBody → string + truncation
    contacts.ts            # handle → Contacts display name (bulk-loaded)
    queries.ts             # all SQL — parameterized
  imessage/
    send.ts                # osascript wrapper for Messages.app send
  storage/
    drafts.ts              # ~/.imessage-mcp/drafts CRUD (incl. sent_at)
scripts/
  install.sh               # rebuild + xattr-clear + re-sign + atomic-mv
```
