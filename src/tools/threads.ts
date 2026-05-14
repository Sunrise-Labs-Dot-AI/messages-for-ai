import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { ListThreadsShape, GetThreadShape, requireSinceOrContactFilter } from "../schema.ts";
import { listThreads, getThreadMessages } from "../chatdb/queries.ts";
import { errorResult, jsonResult } from "./_result.ts";
import { wrapUntrusted, wrapBodyInPlace } from "./_untrusted.ts";

export function registerThreadTools(server: McpServer): void {
  server.registerTool(
    "list_imessage_threads",
    {
      title: "List iMessage threads",
      description:
        "List recent iMessage threads, newest first. Requires either `since` (ISO-8601 within the last 2 years) or `contact_filter` (substring match against handles AND resolved Contact names, min 2 chars). Pass `before` (ISO-8601) to paginate older — use the `oldest_at` field from the previous response. Returns participants (with resolved Contact names where available), the timestamp + preview of the last message, the numeric `thread_id` you pass to `get_imessage_thread`, plus `oldest_at` and `has_more` for pagination.",
      inputSchema: ListThreadsShape,
    },
    async (args) => {
      const err = requireSinceOrContactFilter(args);
      if (err) return errorResult(err);
      try {
        const result = listThreads({
          limit: args.limit,
          sinceIso: args.since,
          beforeIso: args.before,
          contactFilter: args.contact_filter,
        });
        // Spotlight last_message_preview as untrusted data — it's an
        // arbitrary string from a peer's iMessage.
        const wrapped = {
          ...result,
          threads: result.threads.map((t) => ({
            ...t,
            last_message_preview: wrapUntrusted(t.last_message_preview),
          })),
        };
        return jsonResult(wrapped);
      } catch (e) {
        return errorResult(`list_imessage_threads failed: ${(e as Error).message}`);
      }
    }
  );

  server.registerTool(
    "get_imessage_thread",
    {
      title: "Get messages in an iMessage thread",
      description:
        "Return messages in a thread, newest first. `thread_id` comes from `list_imessage_threads`. Pass `before` (ISO-8601) to paginate older. Long bodies are truncated to ~8 KB. Bodies are decoded from both the `text` column and the `attributedBody` blob (used by modern iOS/macOS).",
      inputSchema: GetThreadShape,
    },
    async (args) => {
      try {
        const rows = getThreadMessages({
          threadId: args.thread_id,
          limit: args.limit,
          beforeIso: args.before,
        });
        return jsonResult({ thread_id: args.thread_id, messages: rows.map(wrapBodyInPlace) });
      } catch (e) {
        return errorResult(`get_imessage_thread failed: ${(e as Error).message}`);
      }
    }
  );
}
