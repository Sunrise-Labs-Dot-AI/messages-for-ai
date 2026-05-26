// MIRROR: keep in sync with ../../whatsapp-drafts/src/witness.ts.
// Transport string is per-file (iMessage here). CI lint to enforce drift
// detection is deferred to v0.3.3.
//
// Writes ~/.messages-mcp/last_invocation_imessage.json atomically (temp+rename)
// after every successful tool call so the menubar app can witness Claude
// reaching this MCP. DispatchSourceFileSystemObject on a directory only fires
// on structural events (add/remove/rename), so atomic rename — not in-place
// write — is what makes the watcher reliable.

import { randomBytes } from "node:crypto";
import { mkdirSync, renameSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type {
  McpServer,
  RegisteredTool,
  ToolCallback,
} from "@modelcontextprotocol/sdk/server/mcp.js";
import type {
  AnySchema,
  ZodRawShapeCompat,
} from "@modelcontextprotocol/sdk/server/zod-compat.js";
import type { ToolAnnotations } from "@modelcontextprotocol/sdk/types.js";

const TRANSPORT = "imessage" as const;
const FILENAME = `last_invocation_${TRANSPORT}.json`;

let testHomeOverride: string | null = null;

/** Test seam: route writes to a tempdir during unit tests. Pass null to reset. */
export function _setHomeForTesting(path: string | null): void {
  testHomeOverride = path;
}

function homeDir(): string {
  if (testHomeOverride !== null) return testHomeOverride;
  return process.env.MESSAGES_MCP_HOME ?? join(homedir(), ".messages-mcp");
}

export interface WitnessRecord {
  tool: string;
  ts: string;
  pid: number;
  writer_path: string;
  /** Live chat.db access of THIS (client-launched) MCP process at write
   *  time. The menubar reads this to learn whether *Claude's* MCP can read
   *  chat.db — which differs from the menubar app's own access, because
   *  macOS TCC attributes Full Disk Access to the launching app, not the
   *  binary's identity (see issue #17). iMessage-specific: populated only
   *  when a probe is wired via `setChatDbAccessProbe` (the WhatsApp mirror
   *  never sets one, so the field stays absent there). */
  chatdb_access?: "ok" | "permission_denied" | "not_found" | "error";
}

// Injectable chat.db access probe. Kept as a hook (rather than importing the
// chatdb module here) so this witness module stays generic/mirror-clean and
// unit tests stay pure — only the iMessage server entry point wires a real
// probe. Returns undefined to omit the field.
let chatDbAccessProbe: (() => WitnessRecord["chatdb_access"]) | null = null;

/** Wire the chat.db access probe (iMessage server entry point only). Pass
 *  null to reset (tests). */
export function setChatDbAccessProbe(
  fn: (() => WitnessRecord["chatdb_access"]) | null,
): void {
  chatDbAccessProbe = fn;
}

/**
 * Best-effort: write the witness record. Swallows all errors so a witness
 * failure (disk full, EACCES, transient FS issue) never propagates back to
 * the MCP caller. The MCP must never crash because we couldn't write a
 * diagnostic timestamp.
 */
export function writeLastInvocation(toolName: string): void {
  try {
    const dir = homeDir();
    mkdirSync(dir, { recursive: true });
    // process.execPath is the canonical "real path to the running
    // executable" — in Bun-compiled standalone binaries it returns the
    // path to the compiled .mcp binary. process.argv[0], counterintuitively,
    // returns "bun" (Bun's embedded runtime identity inside the compiled
    // image), which makes the menubar's writer_path codesign check
    // useless. The walkthrough relies on this path to verify the writer's
    // identity — keep it accurate.
    // Probe THIS process's live chat.db access so the menubar can tell
    // whether Claude's MCP (not just the menubar app) has Full Disk Access.
    // Best-effort: a probe throw must never block the witness write.
    let chatdb_access: WitnessRecord["chatdb_access"];
    if (chatDbAccessProbe !== null) {
      try { chatdb_access = chatDbAccessProbe(); } catch { /* omit on failure */ }
    }
    const record: WitnessRecord = {
      tool: toolName,
      ts: new Date().toISOString(),
      pid: process.pid,
      writer_path: process.execPath,
      ...(chatdb_access !== undefined ? { chatdb_access } : {}),
    };
    const finalPath = join(dir, FILENAME);
    // Random suffix on the tmp path prevents a local attacker from
    // pre-creating `last_invocation_imessage.json.tmp.<pid>` as a symlink
    // to a sensitive file (e.g. settings.json) and tricking writeFileSync
    // into overwriting that file. pid alone is predictable from
    // `/proc`-style enumeration; random bytes are not.
    const tmpPath = `${finalPath}.tmp.${process.pid}.${randomBytes(6).toString("hex")}`;
    writeFileSync(tmpPath, JSON.stringify(record));
    renameSync(tmpPath, finalPath);
  } catch {
    // swallow — see function doc
  }
}

/**
 * Wraps server.registerTool, emitting a witness write after the handler
 * resolves SUCCESSFULLY. Handler-thrown errors propagate unchanged AND
 * skip the witness write. Handler-returned MCP error results
 * (`{isError: true, ...}` — the standard MCP failure signal) also skip
 * the witness write. The walkthrough's "Claude reached this MCP" gate
 * uses the witness as proof of success — false-positive greens when
 * Claude got an error back would defeat the entire verification flow
 * (e.g. FDA-not-granted on iMessage would silently pass).
 *
 * Witness errors themselves are absorbed at two layers
 * (writeLastInvocation's own try/catch and this outer try/catch —
 * defense in depth).
 *
 * The generic mirrors the SDK's `registerTool<InputArgs, OutputArgs>`
 * signature so callers see the same `args` typing they'd get calling
 * `server.registerTool` directly. `Parameters<McpServer["registerTool"]>`
 * collapses to `never` because of the overload, so we replicate the
 * signature manually.
 */
export function registerWithWitness<
  InputArgs extends undefined | ZodRawShapeCompat | AnySchema = undefined,
  OutputArgs extends ZodRawShapeCompat | AnySchema = ZodRawShapeCompat | AnySchema,
>(
  server: McpServer,
  name: string,
  config: {
    title?: string;
    description?: string;
    inputSchema?: InputArgs;
    outputSchema?: OutputArgs;
    annotations?: ToolAnnotations;
    _meta?: Record<string, unknown>;
  },
  cb: ToolCallback<InputArgs>,
): RegisteredTool {
  const wrapped = (async (...args: Parameters<ToolCallback<InputArgs>>) => {
    const result = await (
      cb as (...a: Parameters<ToolCallback<InputArgs>>) => Promise<unknown>
    )(...args);
    // Skip witness when the handler returned an MCP error result.
    // Tools in this codebase use errorResult() which returns
    // { isError: true, content: [...] }; we trust that single boolean.
    const isError =
      typeof result === "object" &&
      result !== null &&
      (result as { isError?: unknown }).isError === true;
    if (!isError) {
      try {
        writeLastInvocation(name);
      } catch {
        // swallow — never propagate witness errors to MCP callers
      }
    }
    return result;
  }) as ToolCallback<InputArgs>;
  return server.registerTool(name, config, wrapped);
}
