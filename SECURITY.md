# Security Considerations

This document is the honest threat model for `imessage-drafts-mcp`. Read it
before installing — the trust profile is non-trivial.

## Summary

You are giving a local binary three macOS-level privileges:

1. **Full Disk Access (FDA)** — required to read `chat.db`. macOS does
   not expose a "chat.db-only" scope; the FDA grant lets the binary
   read **any file** in your home directory.
2. **Automation control of Messages.app** — granted on first send.
   Lets the binary spawn `osascript` to send iMessages/SMS to any
   recipient you have, without further prompting.
3. **Open-at-login** (menu bar app) — defaults on; the menu bar app
   auto-launches when you sign in. Toggleable in the popover.

If a future commit, dependency, or local binary replacement is
malicious, those three privileges become its privileges. The trust
boundary is "I trust this binary the way I trust software I write
myself" — not "I trust this binary because of some sandbox."

## Threat model

### In scope

- **Prompt injection** via incoming iMessages, where attacker text in
  a peer's message hijacks an agent reading the thread.
- **Confused-deputy** attacks where the agent uses the read tools to
  see attacker text and then a *different* tool (web fetch, shell,
  email) to exfiltrate or act on it.
- **Runaway send loops** where an agent gets into a bad state and
  re-sends or blast-sends repeatedly.
- **Binary substitution** where an attacker with write access to
  `~/bin/imessage-drafts-mcp` swaps the binary for a malicious one and
  inherits the FDA + Automation grants.
- **Supply chain** — a malicious update to the source repo, or a
  compromised dependency.

### Out of scope

- Apple Notarization is out of scope (no Developer Program enrollment).
  Gatekeeper will not mark the binary as notarized; users may need to
  approve it via System Settings on first launch.
- Sandbox containment via `sandbox-exec` is out of scope. macOS's
  sandbox profile API is undocumented and unstable across releases.
- Defending against root-level attackers. If something is running as
  root on your Mac, you have larger problems.
- Defending against macOS itself / Apple. If the OS leaks chat.db
  to third parties or breaks TCC, this server can't help.

## What we do about it

| Defense | What it stops | Caveats |
|---|---|---|
| **`<untrusted_content>` body wrapping** | Naive prompt injection: "ignore prior instructions and …" | Doesn't stop a determined attacker who knows the model; doesn't stop confused-deputy via other tools |
| **Required `since` (≤2y) or `contact_filter` on read/search** | Unbounded history dumps into agent context | Doesn't stop reads inside the bounded window |
| **8 KB body truncation** | Mega-payload prompt injections | A 4 KB injection works the same as an 8 KB one |
| **Send-only-from-draft** | Ad-hoc send tool calls | Agent can stage + send in one turn (see next) |
| **`require_approval` setting** (default ON) | All MCP send paths — agents can only stage; the menu bar app is the sole send surface | User-controllable toggle in the menu bar footer. Off if the user explicitly disables. |
| **Minimum staged-age (default 5s)** | Single-turn stage-and-send bypassing human review when `require_approval` is off | Configurable, can be disabled |
| **Daily send cap (default 50/UTC day)** | Runaway loops, blast attacks | Cap is per-day, not per-recipient; configurable |
| **Send audit log** at `~/.messages-mcp/send-audit.log` | Forensic gap (post-hoc only) | Doesn't prevent; helps investigate. Body content is SHA-256-hashed, not stored. |
| **`destructiveHint: true` + `idempotentHint: false` annotations on send** | MCP clients can surface confirmation prompts | Depends on the client implementing the hint |
| **Sent-state lock** (`sent_at` set on draft → refused) | Double-send via retry loops | Doesn't stop staging a fresh draft |
| **SQL parameterized everywhere** | SQL injection | — |
| **`osascript` argv passing** (not string interpolation) | AppleScript injection via `to_handle` / `body` | — |
| **UUID validation on `draft_id`** | Path traversal via draft id | — |
| **Drafts dir mode 0600** | Other users on the same Mac reading drafts | Other processes running as you can still read |
| **Stable codesign identifier** | Adhoc rebuilds invalidating FDA on every install | Doesn't stop binary replacement |
| **No network listener, no outbound calls** | Network-based attack surface | — |
| **`PRAGMA query_only = ON` + `readonly: true` on `chat.db`** | Accidental writes corrupting Messages state | — |

## Configuration knobs

User-controllable in the menu bar UI:

- **Require draft approval to send** (default ON). Toggle in the
  popover footer. When on, the MCP `send_draft` tool is
  disabled entirely — every send must come from a human pressing
  Hold-to-Send in the menu bar app. Persists to
  `~/.messages-mcp/settings.json` as `{ "require_approval": bool }`;
  the MCP server reads it on every send call so toggling takes
  effect immediately without restarting any client.

Env vars (configure for trusted automation contexts):

- `IMESSAGE_MIN_DRAFT_AGE_MS` — minimum age (ms) a draft must be before
  it can be sent via MCP. Default `5000`. Set to `0` to disable. Only
  applies when `require_approval` is off.
- `IMESSAGE_DAILY_SEND_CAP` — maximum sends per UTC day. Default `50`.
  Set to `0` to disable.
- `IMESSAGE_MCP_IDENTIFIER` — codesign identifier used by
  `scripts/dev-install.sh`. Default `com.local.imessage-drafts-mcp.dev`. Changing
  this invalidates any existing FDA grant — you'll need to re-toggle
  the FDA entry after the first build with a new identifier.

## What you should do as a user

1. **Read the source before installing.** The codebase is ~3000 lines
   of TypeScript + ~700 lines of Swift. A careful review is feasible.
2. **Build from source.** Don't run prebuilt binaries someone else
   shipped you.
3. **Pin to a tag.** Don't track `main` in production-feeling setups.
4. **Don't pair this server with an agent that also has destructive
   non-iMessage tools** unless you have a reason to. The interesting
   attack is a confused-deputy: read tool sees attacker text → agent
   uses some *other* tool to exfiltrate or act.
5. **Use the menu bar app for the human-review pattern.** Configure
   your MCP client to NOT auto-approve `send_draft`. Have
   agents stage-only; you click Send in the menu bar.
6. **Audit your daily send-audit log occasionally.** If something
   weird happened, it's in `~/.messages-mcp/send-audit.log`.
7. **Treat `~/bin/imessage-drafts-mcp` like an SSH key.** Permissions matter.
   If a compromised app on your Mac could write to your home dir, it
   could replace this binary and inherit the FDA + Automation grants.

## Reporting a vulnerability

For security issues that should not be discussed in public:

- Open a GitHub Security Advisory on this repo (preferred — gives
  the maintainer a private channel and a way to coordinate disclosure).
- Or email the maintainer; see the GitHub profile on the repo.

For things you're comfortable discussing publicly (style nits,
mitigations you think we should add, etc.), open a regular issue.

I (the maintainer) am one person doing this in spare time. Expect a
response within a few days for routine issues; acute security
disclosures will get a same-day acknowledgment when possible.
