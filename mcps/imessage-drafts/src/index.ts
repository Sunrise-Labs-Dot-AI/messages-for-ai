#!/usr/bin/env bun
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";

import { registerThreadTools } from "./tools/threads.ts";
import { registerSearchTool } from "./tools/search.ts";
import { registerDraftTools } from "./tools/drafts.ts";
import { registerTimeTool } from "./tools/time.ts";
import { registerHealthTools } from "./tools/health.ts";
import { migrateLegacyDir } from "./storage/migrate.ts";

async function main() {
  // One-shot migration from the v0.1.x on-disk root (`~/.imessage-mcp/`)
  // to the v0.2.0 root (`~/.messages-mcp/`). Best-effort, non-blocking;
  // logs to stderr on success or failure. Runs before any storage
  // subsystem touches the new directory.
  migrateLegacyDir();

  const server = new McpServer(
    { name: "imessage-drafts-mcp", version: "0.3.2" },
    {
      instructions:
        "Read-only iMessage access (chat.db) plus a local draft-staging API for the macOS Messages app. " +
        "Drafts never auto-send — staging produces a JSON file under ~/.messages-mcp/drafts that the user reviews and dispatches out-of-band (either via the send_draft tool with explicit confirmation, or via the companion menu bar app). " +
        "All listing/search tools require either a `since` (ISO-8601, ≤2 years) or `contact_filter` (≥2 chars) to prevent unbounded history dumps.",
    }
  );

  registerThreadTools(server);
  registerSearchTool(server);
  registerDraftTools(server);
  registerTimeTool(server);
  registerHealthTools(server);

  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch((err) => {
  // Stdout is reserved for JSON-RPC; route diagnostics to stderr.
  process.stderr.write(`fatal: ${(err as Error).message}\n${(err as Error).stack ?? ""}\n`);
  process.exit(1);
});
