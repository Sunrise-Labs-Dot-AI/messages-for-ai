#!/usr/bin/env bun
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";

import { registerThreadTools } from "./tools/threads.ts";
import { registerSearchTool } from "./tools/search.ts";
import { registerDraftTools } from "./tools/drafts.ts";
import { registerTimeTool } from "./tools/time.ts";

async function main() {
  const server = new McpServer(
    { name: "imessage-mcp", version: "0.1.0" },
    {
      instructions:
        "Read-only iMessage access (chat.db) plus a local draft-staging API for the macOS Messages app. " +
        "Drafts never auto-send — staging produces a JSON file under ~/.imessage-mcp/drafts that James reviews and dispatches out-of-band. " +
        "All listing/search tools require either a `since` (ISO-8601, ≤2 years) or `contact_filter` (≥2 chars) to prevent unbounded history dumps.",
    }
  );

  registerThreadTools(server);
  registerSearchTool(server);
  registerDraftTools(server);
  registerTimeTool(server);

  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch((err) => {
  // Stdout is reserved for JSON-RPC; route diagnostics to stderr.
  process.stderr.write(`fatal: ${(err as Error).message}\n${(err as Error).stack ?? ""}\n`);
  process.exit(1);
});
