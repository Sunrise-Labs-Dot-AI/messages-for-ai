// One-shot legacy-directory migration. Runs at MCP server startup.
//
// Background: v0.1.x stored state under `~/.imessage-mcp/`. v0.2.0 renames
// the on-disk root to `~/.messages-mcp/` to make room for sibling MCPs
// (e.g. WhatsApp) under the same umbrella. On a user's first launch of the
// renamed binary, copy the legacy directory into the new location so they
// don't lose drafts / audit log / contacts cache / settings.
//
// Design notes:
// - **Copy, don't move.** The old directory is preserved as a rollback
//   safety net. Users can delete it manually after confirming the new
//   install works.
// - **Best-effort, non-blocking.** Failures log to stderr but don't halt
//   startup — the storage layer recreates whatever's missing.
// - **Sync API** to match the rest of the storage layer (drafts.ts,
//   settings.ts, audit.ts all use node:fs sync calls).
// - **stderr only.** Stdout is reserved for MCP JSON-RPC; anything we
//   write there breaks the protocol stream.
// - **Idempotent.** If the new directory already exists (subsequent runs),
//   migration silently skips. Will NOT overwrite or merge.

import { existsSync, cpSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const LEGACY_DIR_NAME = ".imessage-mcp";
const CURRENT_DIR_NAME = ".messages-mcp";

export function migrateLegacyDir(): void {
  try {
    const home = homedir();
    const oldDir = join(home, LEGACY_DIR_NAME);
    const newDir = join(home, CURRENT_DIR_NAME);

    if (!existsSync(oldDir)) return;
    if (existsSync(newDir)) return;

    cpSync(oldDir, newDir, { recursive: true });
    process.stderr.write(
      `[imessage-drafts-mcp] Migrated state from ${oldDir} to ${newDir}. ` +
        `Old directory preserved; delete it manually after verifying the new install works.\n`
    );
  } catch (err) {
    // Best-effort — never throw. The storage layer recreates whatever's missing.
    process.stderr.write(
      `[imessage-drafts-mcp] Migration check failed (non-fatal): ${(err as Error).message}\n`
    );
  }
}
