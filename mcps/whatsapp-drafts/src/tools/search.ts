import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";

import { callDaemon, DaemonRpcError, DaemonUnavailableError } from "../daemon/rpc-client.ts";
import { SearchInput, SearchShape, isoToMs } from "../schema.ts";
import { errorResult, jsonResult } from "./_result.ts";
import { wrapBodyInPlace } from "./_untrusted.ts";

interface DaemonMessage {
  message_id: string;
  thread_jid: string;
  sender_jid: string;
  /** Resolved sender name from contacts table; null for from_me or
   *  unresolvable senders. */
  sender_name: string | null;
  from_me: boolean;
  ts: number;
  body: string | null;
  body_sha256: string | null;
  message_type: string;
  attachment_meta: { caption?: string; filename?: string; mime?: string } | null;
  reply_to_id: string | null;
}

export function registerSearchTool(server: McpServer) {
  server.tool(
    "search_whatsapps",
    "Case-insensitive substring search over cached WhatsApp message bodies. " +
      "Query must be ≥2 chars. Either `since` or `contact_filter` is required.",
    SearchShape,
    async (rawArgs) => {
      const parsed = SearchInput.safeParse(rawArgs);
      if (!parsed.success) return errorResult(parsed.error.errors.map((e) => e.message).join("; "));
      const args = parsed.data;
      try {
        const { messages } = await callDaemon<{ messages: DaemonMessage[] }>("searchMessages", {
          query: args.query,
          since: isoToMs(args.since),
          contact_filter: args.contact_filter,
          limit: args.limit,
        });
        return jsonResult({ ok: true, messages: messages.map(wrapBodyInPlace) });
      } catch (e) {
        if (e instanceof DaemonUnavailableError) return errorResult(e.message);
        if (e instanceof DaemonRpcError) return errorResult(`daemon error (${e.code}): ${e.message}`);
        return errorResult(`unexpected error: ${(e as Error).message}`);
      }
    },
  );
}
