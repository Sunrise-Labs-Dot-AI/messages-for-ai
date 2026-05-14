import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { CurrentTimeShape } from "../schema.ts";
import { jsonResult } from "./_result.ts";

export function registerTimeTool(server: McpServer): void {
  server.registerTool(
    "get_imessage_current_time",
    {
      title: "Current time (for constructing `since` filters)",
      description:
        "Returns the current time in ISO-8601 (UTC) plus the same instant formatted in America/Los_Angeles. Use this when constructing the `since` parameter for list/search tools so you don't have to guess timezone offsets.",
      inputSchema: CurrentTimeShape,
    },
    async () => {
      const now = new Date();
      const laFormatter = new Intl.DateTimeFormat("en-CA", {
        timeZone: "America/Los_Angeles",
        year: "numeric",
        month: "2-digit",
        day: "2-digit",
        hour: "2-digit",
        minute: "2-digit",
        second: "2-digit",
        hour12: false,
      });
      return jsonResult({
        utc_iso: now.toISOString(),
        la_local: laFormatter.format(now),
        epoch_ms: now.getTime(),
      });
    }
  );
}
