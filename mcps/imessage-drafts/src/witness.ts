// MIRROR: keep in sync with ../../whatsapp-drafts/src/witness.ts.
// Transport string is per-file (iMessage here). CI lint to enforce drift
// detection is deferred to v0.3.3.
//
// Writes ~/.messages-mcp/last_invocation_imessage.json atomically (temp+rename)
// after every successful tool call so the menubar app can witness Claude
// reaching this MCP. DispatchSourceFileSystemObject on a directory only fires
// on structural events (add/remove/rename), so atomic rename — not in-place
// write — is what makes the watcher reliable.

import { mkdirSync, renameSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";

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
    const record: WitnessRecord = {
      tool: toolName,
      ts: new Date().toISOString(),
      pid: process.pid,
      writer_path: process.argv[0] ?? "",
    };
    const finalPath = join(dir, FILENAME);
    const tmpPath = `${finalPath}.tmp.${process.pid}`;
    writeFileSync(tmpPath, JSON.stringify(record));
    renameSync(tmpPath, finalPath);
  } catch {
    // swallow — see function doc
  }
}

/**
 * Wraps server.registerTool, emitting a witness write after the handler
 * resolves. Errors thrown by the handler propagate unchanged; witness errors
 * are absorbed at two layers (writeLastInvocation's own try/catch and this
 * outer try/catch — defense in depth).
 *
 * Generic preserves the SDK's input-schema → callback-args type linkage at
 * each callsite; callers see the same `args` typing they would calling
 * `server.registerTool` directly.
 */
export function registerWithWitness<
  Cfg extends Parameters<McpServer["registerTool"]>[1],
  Cb extends Parameters<McpServer["registerTool"]>[2],
>(
  server: McpServer,
  name: string,
  config: Cfg,
  cb: Cb,
): ReturnType<McpServer["registerTool"]> {
  const wrapped = (async (...args: Parameters<Cb>) => {
    const result = await (cb as (...a: Parameters<Cb>) => unknown)(...args);
    try {
      writeLastInvocation(name);
    } catch {
      // swallow — never propagate witness errors to MCP callers
    }
    return result;
  }) as unknown as Cb;
  return server.registerTool(name, config, wrapped);
}
