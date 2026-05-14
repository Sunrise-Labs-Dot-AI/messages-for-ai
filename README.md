# imessage-mcp

A local MCP server that exposes read-only access to your macOS iMessages
(`~/Library/Messages/chat.db`) and lets agents stage outgoing drafts as
local JSON files. **Drafts never auto-send.**

- P0 — read iMessage threads, messages, and search.
- P1 — stage drafts under `~/.imessage-mcp/drafts/`.
- P2 — approval-gated send of staged drafts via AppleScript automation.
- Designed for **local MCP clients** (Claude Desktop, Claude Code, Codex
  CLI). No network listener. No cloud component.

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
| `send_imessage_draft` | **Destructive.** Send a staged draft via Messages.app. Refuses duplicate sends. |
| `get_imessage_current_time` | UTC + LA-local timestamps, for building `since` filters. |

Hard guardrails:

- `since` older than 2 years → rejected (no deep-history dumps).
- `query` shorter than 2 chars → rejected.
- All message bodies truncated at ~8 KB with a marker.

## One-time setup

### 1. Build + install

```sh
cd ~/Documents/Claude/Projects/imessage-mcp
bun install
bun run install:bin
# → builds bin/imessage-mcp, clears xattrs, re-signs with a stable identifier
#   (com.jamesheath.imessage-mcp), atomic-moves to ~/bin/imessage-mcp,
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
3. Press **⌘⇧G**, paste `/Users/jamesheath/bin/imessage-mcp`, press Enter.
4. Confirm the toggle is **on**.

(Granting FDA to the binary itself — not to Claude/Codex/Terminal — is
the tight option: only this one program gets the privilege, not every
tool the parent spawns.)

### 4. Wire up the MCP clients

**Claude Desktop** — `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "imessages": {
      "command": "/Users/jamesheath/bin/imessage-mcp"
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
    "imessages": { "command": "/Users/jamesheath/bin/imessage-mcp" }
  }
}
```

**Codex CLI** — `~/.codex/config.toml`:

```toml
[mcp_servers.imessages]
command = "/Users/jamesheath/bin/imessage-mcp"
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
bun run install:bin
```

After this, **restart Claude Desktop** (and any other MCP client) so the
client picks up the new binary on its next stdio spawn.

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
