// MCP draft tools — stage / list / get / discard / send.
//
// Send path:
//   - If settings.require_approval = true (default), MCP send returns
//     PENDING_APPROVAL — the menu bar app's hold-to-fire is the only path
//     that can flip the draft to "approved".
//   - If settings.require_approval = false (a user opts in for fully
//     automated sends), the MCP tool calls daemon.approveDraft itself
//     immediately before invoking daemon.sendDraft.
//
// Daemon errors map to clear MCP error messages. The RPC error CODES
// (-32020..-32027) are propagated so a smart client can switch on them,
// but we always also include a human-readable message.

import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";

import { callDaemon, DaemonRpcError, DaemonUnavailableError } from "../daemon/rpc-client.ts";
import { registerWithWitness } from "../witness.ts";
import { DraftIdInput, DraftIdShape, StageDraftInput, StageDraftShape } from "../schema.ts";
import type { Settings } from "../settings.ts";
import { readSettings, SettingsError } from "../settings.ts";
import { errorResult, jsonResult } from "./_result.ts";
import { wrapBodyInPlace, wrapUntrusted } from "./_untrusted.ts";

const RPC_CODE = {
  PENDING_APPROVAL: -32020,
  MIN_AGE_NOT_REACHED: -32021,
  INTER_SEND_TOO_FAST: -32022,
  BURST_LIMIT_HIT: -32023,
  DAILY_CAP_HIT: -32024,
  SEND_FAILED: -32025,
  DRAFT_NOT_FOUND: -32026,
  SETTINGS_ERROR: -32027,
};

const RPC_NAME: Record<number, string> = {
  [RPC_CODE.PENDING_APPROVAL]: "PENDING_APPROVAL",
  [RPC_CODE.MIN_AGE_NOT_REACHED]: "MIN_AGE_NOT_REACHED",
  [RPC_CODE.INTER_SEND_TOO_FAST]: "INTER_SEND_TOO_FAST",
  [RPC_CODE.BURST_LIMIT_HIT]: "BURST_LIMIT_HIT",
  [RPC_CODE.DAILY_CAP_HIT]: "DAILY_CAP_HIT",
  [RPC_CODE.SEND_FAILED]: "SEND_FAILED",
  [RPC_CODE.DRAFT_NOT_FOUND]: "DRAFT_NOT_FOUND",
  [RPC_CODE.SETTINGS_ERROR]: "SETTINGS_ERROR",
};

interface DraftRpc {
  id: string;
  schema_version: number;
  platform: "whatsapp";
  approval_state: "pending" | "approved";
  to_handle: string;
  body: string;
  staged_at: string;
  sent_at: string | null;
  source: string;
  context_messages: Array<{
    message_id: string;
    sender_handle: string;
    sender_name: string | null;
    from_me: boolean;
    sent_at: string;
    body: string | null;
  }>;
  context_diagnostic: null | "no_thread_match" | "thread_empty" | "error";
  induced_by_unknown_contact: boolean;
}

/** Wrap untrusted fields (peer-authored context messages) but leave
 *  the agent-authored `body` clean.
 *
 *  Both message bodies AND sender_name are peer-controlled: sender_name
 *  comes from the WhatsApp contact's profile (display_name / push_name in
 *  the contacts table, populated from Baileys contact events). A contact
 *  who sets their profile name to a tag-close payload could otherwise
 *  inject directives into the model's view of the staged draft. The
 *  sanitizeIncomingBody pass at write time (in storage/messages.ts) does
 *  NOT cover contact names — they go through the contacts table on a
 *  different path — so the wrap is essential at the MCP response
 *  boundary. */
function maskDraft(d: DraftRpc): DraftRpc {
  return {
    ...d,
    context_messages: d.context_messages.map((m) => ({
      ...m,
      body: m.body == null ? null : wrapBodyInPlace({ body: m.body }).body,
      sender_name: m.sender_name == null ? null : wrapUntrusted(m.sender_name),
    })),
  };
}

export function registerDraftTools(server: McpServer) {
  registerWithWitness(
    server,
    "stage_whatsapp_draft",
    {
      description:
        "Stage an outbound WhatsApp message as a DRAFT (does NOT send). The user " +
        "approves via the menu bar app's hold-to-fire (Phase 3) or, if " +
        "settings.require_approval is OFF, via send_whatsapp_draft. Drafts " +
        "include a 5-message thread-context snapshot for the approval surface.",
      inputSchema: StageDraftShape,
    },
    async (raw) => {
      const parsed = StageDraftInput.safeParse(raw);
      if (!parsed.success) return errorResult(parsed.error.errors.map((e) => e.message).join("; "));
      try {
        const { draft } = await callDaemon<{ draft: DraftRpc }>("stageDraft", parsed.data);
        return jsonResult({ ok: true, draft: maskDraft(draft) });
      } catch (e) {
        return mapDaemonError(e);
      }
    },
  );

  registerWithWitness(
    server,
    "list_whatsapp_drafts",
    {
      description:
        "List currently-staged drafts, newest-first. Drafts with sent_at set " +
        "are returned until the daemon's daily sweep purges them.",
    },
    async () => {
      try {
        const r = await callDaemon<{ drafts: DraftRpc[]; skipped: number }>("getDrafts");
        return jsonResult({ ok: true, drafts: r.drafts.map(maskDraft), skipped: r.skipped });
      } catch (e) {
        return mapDaemonError(e);
      }
    },
  );

  registerWithWitness(
    server,
    "get_whatsapp_draft",
    {
      description: "Retrieve a single staged draft by id.",
      inputSchema: DraftIdShape,
    },
    async (raw) => {
      const parsed = DraftIdInput.safeParse(raw);
      if (!parsed.success) return errorResult(parsed.error.errors.map((e) => e.message).join("; "));
      try {
        const { draft } = await callDaemon<{ draft: DraftRpc }>("getDraft", parsed.data);
        return jsonResult({ ok: true, draft: maskDraft(draft) });
      } catch (e) {
        return mapDaemonError(e);
      }
    },
  );

  registerWithWitness(
    server,
    "discard_whatsapp_draft",
    {
      description: "Delete a staged draft. The draft must not have been sent.",
      inputSchema: DraftIdShape,
    },
    async (raw) => {
      const parsed = DraftIdInput.safeParse(raw);
      if (!parsed.success) return errorResult(parsed.error.errors.map((e) => e.message).join("; "));
      try {
        const r = await callDaemon<{ ok: true; existed: boolean }>("discardDraft", parsed.data);
        return jsonResult(r);
      } catch (e) {
        return mapDaemonError(e);
      }
    },
  );

  registerWithWitness(
    server,
    "send_whatsapp_draft",
    {
      description:
        "Send a previously-staged WhatsApp draft. Subject to the full check ladder: " +
        "approval-gate (default ON), minimum staged age, inter-send delay, " +
        "burst limit, daily cap. Returns explicit error codes so callers can " +
        "distinguish 'not approved' from 'cap hit' from 'send failed'.",
      inputSchema: DraftIdShape,
    },
    async (raw) => {
      const parsed = DraftIdInput.safeParse(raw);
      if (!parsed.success) return errorResult(parsed.error.errors.map((e) => e.message).join("; "));

      // Read settings on THIS side too so we can pre-approve when
      // require_approval is OFF. (The daemon also reads settings inside
      // sendDraft for the rate-limit checks.)
      let settings: Settings;
      try {
        settings = readSettings();
      } catch (e) {
        if (e instanceof SettingsError) return errorResult(`SETTINGS_ERROR: ${e.message}`);
        throw e;
      }

      if (!settings.require_approval) {
        // Flip approval_state for the user. In production this happens
        // via the menu bar app's hold-to-fire UI.
        try {
          await callDaemon("approveDraft", parsed.data);
        } catch (e) {
          return mapDaemonError(e);
        }
      }

      try {
        const r = await callDaemon<{
          ok: true;
          draft_id: string;
          message_id: string;
          sent_at: string;
        }>("sendDraft", parsed.data);
        return jsonResult(r);
      } catch (e) {
        return mapDaemonError(e);
      }
    },
  );
}

function mapDaemonError(e: unknown) {
  if (e instanceof DaemonUnavailableError) return errorResult(e.message);
  if (e instanceof DaemonRpcError) {
    const name = RPC_NAME[e.code];
    if (name != null) return errorResult(`${name}: ${e.message}`);
    return errorResult(`daemon error (${e.code}): ${e.message}`);
  }
  return errorResult(`unexpected error: ${(e as Error).message}`);
}
