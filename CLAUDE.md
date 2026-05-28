# Messages for AI — project guide

A macOS menu bar app that gives Claude **read-only** access to iMessage and
WhatsApp plus a **staged-draft → human-approval → send** flow. Product stance:
"AI proposes, you approve." Differentiator vs. Anthropic's iMessage plugin is
the approval gate, not protocol features.

## Layout

- `menubar/` — SwiftUI menu bar app (SwiftPM, macOS 14+). The UI + the
  draft-approval surface + all health/walkthrough logic.
- `mcps/imessage-drafts/` — iMessage stdio MCP **+ chat.db daemon**
  (Bun/TypeScript). The MCP is a thin socket client; the daemon (`src/daemon/`)
  performs all `~/Library/Messages/chat.db` + AddressBook reads because it's
  launched by the menu-bar app (which holds Full Disk Access) — see "FDA is
  launcher-attributed" below.
- `mcps/whatsapp-drafts/` — WhatsApp stdio MCP + Baileys-backed daemon
  (Bun/TypeScript).
- `site/` — marketing site (Vercel project `messages-for-ai-marketing-site`,
  domain `messagesfor.ai`).
- `scripts/` — release + dev-install for the MCP binaries.
- `menubar/scripts/` — dev-install + entitlements for the .app.

## Build & dev loop

Dev iteration (~10s, Developer ID signed, NOT notarized):

```
(cd menubar && bash scripts/dev-install.sh)   # rebuild + reinstall the .app
bash scripts/dev-install.sh                    # rebuild all MCP Mach-Os into the .app
```

Run menu bar tests / type-check after Swift changes:

```
(cd menubar && swift build && swift test)
```

MCP unit tests:

```
(cd mcps/imessage-drafts && bun test)
(cd mcps/whatsapp-drafts && bun test)
```

Shipping a release (notarized, reserved for actual GitHub Releases):

```
bash scripts/build-release.sh vX.Y.Z   # → dist/messages-for-ai-vX.Y.Z.zip
bash scripts/build-dmg.sh vX.Y.Z       # → polished .dmg (stable name Messages-for-AI.dmg)
```

## Load-bearing conventions

- **FDA is launcher-attributed, NOT codesign-identifier-keyed.** macOS
  attributes a process's Full Disk Access to its *responsible process* (the app
  that launched it), not to the binary's codesign `Identifier=`. So a
  Claude-launched MCP (Claude Desktop, or the `com.anthropic.claude-code` CLI)
  only gets FDA if **Claude** has FDA — the `Messages for AI` grant on the
  bundle does NOT reach it. (This corrects the earlier assumption; see the #17
  saga. Verified: two sibling MCPs under one FDA-holding Claude Desktop — the
  one Desktop launched directly reads chat.db; the one `claude-code` launched is
  denied. Same binary, same grant.) **Architecture consequence:** all FDA-gated
  reads live in `imessage-drafts-daemon`, which the **menu-bar app launches** —
  so the daemon's responsible process is the menu-bar (which the user grants
  `Messages for AI` FDA). The iMessage MCP is a thin client over
  `~/.messages-mcp/daemon.sock`, peer-authed by codesign Identifier+Team (MCP
  and daemon share `com.sunriselabs.messages-for-ai`). **Claude never needs
  FDA.** The WhatsApp daemon already worked this way; the iMessage daemon
  mirrors it (`mcps/imessage-drafts/src/daemon/` reuses peer-auth/peer-pid/
  codesign/rpc-client from the WhatsApp daemon).
- **One codesign identifier across every inner Mach-O.**
  `com.sunriselabs.messages-for-ai` is signed onto the menu bar binary and all
  four backends (imessage MCP + daemon, whatsapp MCP + daemon). It's what makes
  peer-auth's same-identity check work and keeps the bundle seal coherent.
  **Sign each inner Mach-O explicitly with `--identifier` before sealing;
  `codesign --deep` clobbers `--identifier`, so the bundle seal uses NO
  `--deep`.** A Developer-ID re-sign *preserves* the menu-bar's FDA grant (it's
  keyed to the signing identity, cdhash-tolerant), so dev-install cycles don't
  require re-granting FDA.
- **State/config locations.** Settings: `~/.messages-mcp/settings.json` (v2
  schema, nested `transports.{imessage,whatsapp}`; flat `require_approval`
  mirrored at root for older MCP processes). Drafts:
  `~/.messages-mcp/drafts/`. iMessage daemon: `~/.messages-mcp/daemon.sock` +
  `daemon.pid`; log `~/.messages-mcp/logs/imessage-daemon.log`. WhatsApp daemon
  state: `~/.whatsapp-mcp/` (session.db, daemon.sock, daemon.pid, messages.db,
  audit.db, drafts/); log `~/.messages-mcp/logs/whatsapp-daemon.log`.
- **Non-popover UI uses real `Window` scenes** (`Window(id:)` +
  `openWindow`/`dismissWindow`), not `MenuBarExtra(.window)` sheets (focus-bleed
  dismisses the popover). `applicationShouldTerminateAfterLastWindowClosed =
  false` keeps the menu bar alive; activation policy flips `.accessory` ↔
  `.regular` by visible-window count.
- **Hardened Runtime needs per-Mach-O entitlements.** Each inner binary must
  embed its own `--entitlements` (the Bun-compiled binaries need
  `com.apple.security.cs.allow-jit` + `allow-unsigned-executable-memory` or Bun's
  JIT SIGTRAPs on first hot-loop recompile). Bundle-level entitlements do NOT
  propagate to inner Mach-Os.

## Notarization diagnostic (notarytool 1.1.0)

`notarytool submit` can exit with **SIGBUS / signal 10** *after* the upload
completes and Apple acknowledges it — the crash is in notarytool's
response-printing path (`__CFStringCreateImmutableFunnel3`), **not** a failure of
the submission and **not** RAM/coalition pressure (those were earlier
mis-diagnoses). The release scripts handle it: wrap `submit` in `set +e`, recover
the UUID from `notarytool history` when the JSON output is blanked, and poll with
`notarytool info --output-format json` (short response) rather than
`notarytool wait` (long response re-triggers the formatter crash).

Notary keychain profile is `imessage-mcp-notary` (legacy name from the
imessage-mcp era). Override with `NOTARY_PROFILE` if your keychain differs.

## Session memory

Cross-session context (decisions, what shipped, carryover) lives in Obsidian at
`~/Documents/Vault/Projects/Messages for AI/Session Memory.md`. Read the latest
session entry before resuming work.
