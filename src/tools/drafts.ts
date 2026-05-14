import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import {
  StageDraftShape,
  ListDraftsShape,
  GetDraftShape,
  DiscardDraftShape,
  SendDraftShape,
} from "../schema.ts";
import { stageDraft, listDrafts, getDraft, discardDraft, markDraftSent, draftsDir } from "../storage/drafts.ts";
import { recentContextForRecipient } from "../chatdb/queries.ts";
import type { DraftContextMessage, ContextLookupDiagnostic } from "../chatdb/queries.ts";
import { sendIMessage } from "../imessage/send.ts";
import { appendAudit, checkDailyCap } from "../imessage/audit.ts";
import { errorResult, jsonResult } from "./_result.ts";
import { wrapBodyInPlace } from "./_untrusted.ts";
import type { Draft } from "../storage/drafts.ts";

// Minimum age (ms) before a staged draft is allowed to be sent. Forces
// a multi-turn handoff between staging and sending, so a single agent
// turn can't stage + immediately send without giving the human (or a
// destructive-hint prompt in the MCP client) a chance to intervene.
// Default 5 seconds; configurable via IMESSAGE_MIN_DRAFT_AGE_MS.
// Set to 0 to disable (e.g., for trusted automation/cron flows).
function minDraftAgeMs(): number {
  const raw = process.env["IMESSAGE_MIN_DRAFT_AGE_MS"];
  if (raw == null) return 5000;
  const n = Number(raw);
  if (!Number.isFinite(n) || n < 0) return 5000;
  return Math.floor(n);
}

// Wrap the context_messages bodies (chat.db sourced, attacker-influenced)
// when returning a draft to an agent. The draft's own body is agent-authored
// and stays raw. The on-disk JSON also stays raw — the menu bar app reads
// it directly and shouldn't see the delimiters in its bubble UI.
function wrapDraftContext(d: Draft | null): Draft | null {
  if (!d || !d.context_messages) return d;
  return { ...d, context_messages: d.context_messages.map(wrapBodyInPlace) };
}

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
        // Best-effort thread-context lookup. The function never throws
        // (it catches internally and returns status="error"), but we
        // belt-and-suspender it anyway. The diagnostic is always
        // attached so a null context_messages is self-explaining in
        // the menu bar UI.
        let context: DraftContextMessage[] | null = null;
        let diagnostic: ContextLookupDiagnostic | null = null;
        try {
          const result = recentContextForRecipient({
            recipientHandle: args.to_handle,
            threadId: args.in_reply_to_thread_id,
            limit: 5,
          });
          context = result.messages.length > 0 ? result.messages : null;
          diagnostic = result.diagnostic;
        } catch (e) {
          context = null;
          diagnostic = {
            status: "error",
            canonical_recipient: null,
            matched_handle_ids: [],
            chat_id: null,
            message_count: 0,
            error: (e as Error).message,
          };
        }

        const result = stageDraft({
          to_handle: args.to_handle,
          body: args.body,
          in_reply_to_thread_id: args.in_reply_to_thread_id ?? null,
          source: args.source ?? null,
          context_messages: context,
          context_diagnostic: diagnostic,
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
        return jsonResult({ draft: wrapDraftContext(draft) });
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
        "Send a previously-staged iMessage draft via the Messages.app AppleScript automation surface. Requires a draft_id from `stage_imessage_draft` — there is no ad-hoc send. Tries iMessage first, falls back to SMS if the recipient is not on iMessage. " +
        "Refuses if: (a) the draft has already been sent (`sent_at` set); " +
        "(b) the draft is younger than the minimum staged-age (default 5000ms, env IMESSAGE_MIN_DRAFT_AGE_MS) — this prevents a single agent turn from staging and immediately sending without giving the user / MCP client confirmation surface a chance to intervene; " +
        "(c) the daily send cap has been reached (default 50 sends per UTC day, env IMESSAGE_DAILY_SEND_CAP) — circuit breaker against runaway loops. " +
        "Every successful send appends a JSON line to ~/.imessage-mcp/send-audit.log with timestamp, recipient, and a SHA-256 of the body. " +
        "First call to this tool triggers a one-time macOS prompt: 'Allow <parent app> to control Messages.app?' — approve it to enable sending.",
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

        // Guardrail #1: minimum staged-age. Forces a multi-turn handoff
        // so a single agent turn can't stage + immediately send.
        const minAge = minDraftAgeMs();
        if (minAge > 0) {
          const stagedMs = Date.parse(draft.staged_at);
          if (Number.isFinite(stagedMs)) {
            const ageMs = Date.now() - stagedMs;
            if (ageMs < minAge) {
              const waitMs = minAge - ageMs;
              return errorResult(
                `draft ${args.draft_id} was staged ${ageMs}ms ago; minimum is ${minAge}ms. ` +
                `Wait ${waitMs}ms and retry, or use the menu bar app to send sooner. ` +
                `Adjust via IMESSAGE_MIN_DRAFT_AGE_MS (set 0 to disable).`
              );
            }
          }
        }

        // Guardrail #2: daily send cap. Catastrophic-failure circuit
        // breaker — caps total sends per UTC day (default 50).
        const capErr = checkDailyCap();
        if (capErr) return errorResult(capErr);

        // Send.
        const result = await sendIMessage(draft.to_handle, draft.body);
        if (!result.ok || !result.service) {
          return errorResult(`send failed: ${result.error ?? "unknown error"} (took ${result.duration_ms}ms)`);
        }
        const sentAt = new Date().toISOString();
        const updated = markDraftSent(draft.id, sentAt, result.service);

        // Guardrail #3: audit log. Append-only record per send, for
        // forensic review and as input to the daily-cap counter.
        try {
          appendAudit({
            draft_id: draft.id,
            to_handle: draft.to_handle,
            body: draft.body,
            service: result.service,
            ts: new Date(sentAt),
          });
        } catch (e) {
          // Don't fail the send if the audit write fails — the message
          // already went out. Surface the error in the response so a
          // human reviewer sees it.
          return jsonResult({
            ok: true,
            draft_id: draft.id,
            service: result.service,
            sent_at: sentAt,
            duration_ms: result.duration_ms,
            draft: updated,
            audit_warning: `send succeeded but audit log write failed: ${(e as Error).message}`,
          });
        }

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
