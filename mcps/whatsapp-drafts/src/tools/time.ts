import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";

import { jsonResult } from "./_result.ts";

export function registerTimeTool(server: McpServer) {
  server.tool(
    "get_whatsapp_current_time",
    "Return the current local time (the daemon and MCP host's system clock). " +
      "Useful for resolving relative `since` filters like 'last 24h'.",
    z.object({}).shape,
    async () => {
      const now = new Date();
      return jsonResult({
        ok: true,
        iso: now.toISOString(),
        unix_ms: now.getTime(),
        timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
      });
    },
  );
}
