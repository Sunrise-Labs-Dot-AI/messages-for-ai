# Messages for AI — project guide

A macOS menu bar app that gives Claude **read-only** access to iMessage and
WhatsApp plus a **staged-draft → human-approval → send** flow. Product stance:
"AI proposes, you approve." Differentiator vs. Anthropic's iMessage plugin is
the approval gate, not protocol features.

## Layout

- `menubar/` — SwiftUI menu bar app (SwiftPM, macOS 14+). The UI + the
  draft-approval surface + all health/walkthrough logic.
- `mcps/imessage-drafts/` — iMessage stdio MCP (Bun/TypeScript). Reads
  `~/Library/Messages/chat.db`.
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

- **One codesign identifier across every inner Mach-O.**
  `com.sunriselabs.messages-for-ai` is signed onto the menu bar binary, the
  iMessage MCP, the WhatsApp MCP, and the WhatsApp daemon. macOS TCC keys Full
  Disk Access by the running process's codesign `Identifier=`, so a single FDA
  grant on the `.app` covers every binary. **Sign each inner Mach-O explicitly
  with `--identifier` before sealing; `codesign --deep` clobbers `--identifier`,
  so the bundle seal uses NO `--deep`.** This is also why the menu bar can probe
  its own `chat.db` access as a proxy for the iMessage MCP's FDA state.
- **State/config locations.** Settings: `~/.messages-mcp/settings.json` (v2
  schema, nested `transports.{imessage,whatsapp}`; flat `require_approval`
  mirrored at root for older MCP processes). Drafts:
  `~/.messages-mcp/drafts/`. WhatsApp daemon state: `~/.whatsapp-mcp/`
  (session.db, daemon.sock, daemon.pid, messages.db, audit.db, drafts/). Daemon
  logs: `~/.messages-mcp/logs/whatsapp-daemon.log`.
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
