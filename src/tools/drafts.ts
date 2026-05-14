import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import {
  StageDraftShape,
  ListDraftsShape,
  GetDraftShape,
  DiscardDraftShape,
  SendDraftShape,
} from "../schema.ts";
import { stageDraft, listDrafts, getDraft, discardDraft, markDraftSent, draftsDir } from "../storage/drafts.ts";
import { sendIMessage } from "../imessage/send.ts";
import { errorResult, jsonResult } from "./_result.ts";

export function registerDraftTools(server: McpServer): void {
  server.registerTool(
    "stage_imessage_draft",
    {
      title: "Stage an iMessage draft (does NOT send)",
      description:
        "Stage a draft iMessage as a local JSON file under ~/.imessage-mcp/drafts. Does NOT send. Returns the draft id and file path. " +
        "Drafts are reviewed and sent out-of-band — either via `send_imessage_draft` (with human confirmation in the MCP client) or via the companion menu bar app. " +
        "Pass `source` to identify yourself: a short human-readable label (e.g. \"Claude Desktop / morning triage\", \"Claude Code in personal-assistant\"). The reviewer will see this verbatim next to the draft body.",
      inputSchema: StageDraftShape,
    },
    async (args) => {
      try {
        const result = stageDraft({
          to_handle: args.to_handle,
          body: args.body,
          in_reply_to_thread_id: args.in_reply_to_thread_id ?? null,
          source: args.source ?? null,
        });
        return jsonResult({ ok: true, draft_id: result.draft.id, path: result.path, draft: result.draft });
      } catch (e) {
        return errorResult(`stage_imessage_draft failed: ${(e as Error).message}`);
      }
    }
  );

  server.registerTool(
    "list_imessage_drafts",
    {
      title: "List staged iMessage drafts",
      description: `List staged iMessage drafts, newest first. Drafts live under ${draftsDir()}.`,
      inputSchema: ListDraftsShape,
    },
    async (args) => {
      try {
        return jsonResult({ drafts: listDrafts(args.limit) });
      } catch (e) {
        return errorResult(`list_imessage_drafts failed: ${(e as Error).message}`);
      }
    }
  );

  server.registerTool(
    "get_imessage_draft",
    {
      title: "Get a staged iMessage draft",
      description: "Fetch a single staged iMessage draft by id.",
      inputSchema: GetDraftShape,
    },
    async (args) => {
      try {
        const draft = getDraft(args.draft_id);
        if (!draft) return errorResult(`draft not found: ${args.draft_id}`);
        return jsonResult({ draft });
      } catch (e) {
        return errorResult(`get_imessage_draft failed: ${(e as Error).message}`);
      }
    }
  );

  server.registerTool(
    "discard_imessage_draft",
    {
      title: "Discard a staged iMessage draft",
      description: "Delete a staged iMessage draft file.",
      inputSchema: DiscardDraftShape,
    },
    async (args) => {
      try {
        const ok = discardDraft(args.draft_id);
        if (!ok) return errorResult(`draft not found: ${args.draft_id}`);
        return jsonResult({ ok: true, draft_id: args.draft_id });
      } catch (e) {
        return errorResult(`discard_imessage_draft failed: ${(e as Error).message}`);
      }
    }
  );

  server.registerTool(
    "send_imessage_draft",
    {
      title: "Send a staged iMessage draft (DESTRUCTIVE — actually sends)",
      description:
        "Send a previously-staged iMessage draft via the Messages.app AppleScript automation surface. Requires a draft_id from `stage_imessage_draft` (no ad-hoc send — every send goes through staging so the draft text is observable in the transcript first). Refuses if the draft has already been sent (`sent_at` set). Tries iMessage first, falls back to SMS if the recipient is not on iMessage. First call triggers a one-time macOS prompt: 'Allow <parent app> to control Messages.app?' — approve it to enable sending.",
      inputSchema: SendDraftShape,
      annotations: {
        title: "Send iMessage draft",
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: false,
        openWorldHint: true,
      },
    },
    async (args) => {
      try {
        const draft = getDraft(args.draft_id);
        if (!draft) return errorResult(`draft not found: ${args.draft_id}`);
        if (draft.sent_at) {
          return errorResult(
            `draft ${args.draft_id} was already sent at ${draft.sent_at} via ${draft.send_service ?? "unknown"}; refusing duplicate send`
          );
        }
        const result = await sendIMessage(draft.to_handle, draft.body);
        if (!result.ok || !result.service) {
          return errorResult(`send failed: ${result.error ?? "unknown error"} (took ${result.duration_ms}ms)`);
        }
        const sentAt = new Date().toISOString();
        const updated = markDraftSent(draft.id, sentAt, result.service);
        return jsonResult({
          ok: true,
          draft_id: draft.id,
          service: result.service,
          sent_at: sentAt,
          duration_ms: result.duration_ms,
          draft: updated,
        });
      } catch (e) {
        return errorResult(`send_imessage_draft failed: ${(e as Error).message}`);
      }
    }
  );
}
