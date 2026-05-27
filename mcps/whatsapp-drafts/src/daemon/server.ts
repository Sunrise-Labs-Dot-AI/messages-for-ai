// Unix-socket JSON-RPC server. Speaks newline-delimited JSON-RPC 2.0.
// Single source of truth for what the MCP binary and the menu bar app
// can ask the daemon to do.
//
// Methods (Phase 1 read-only + recovery):
//   - getThreads({ since?, contact_filter?, limit? })
//   - getThread({ thread_jid, before_ts?, limit? })
//   - searchMessages({ query, since?, contact_filter?, limit? })
//   - getMessageFull({ thread_jid, message_id })
//   - getConnectionStatus()
//   - subscribe(channel)   // "qr" | "state" — server-pushed events
//   - unsubscribe(subscription_id)
//   - unlinkAndReset()     // menu-bar-only; deletes session, clears sentinel
//
// Methods (Phase 2 — drafts/send; placeholder):
//   - stageDraft / getDrafts / getDraft / discardDraft / sendDraft

import { createServer, type Server, type Socket } from "node:net";
import { existsSync, unlinkSync } from "node:fs";

import { PATHS } from "../paths.ts";
import type { WhatsAppConnection } from "./connection.ts";
import { authenticatePeer, refuseDevModeInProduction } from "./peer-auth.ts";
import {
  listThreads,
  getThreadMessages,
  searchMessages,
  getMessageFull,
  getContactDisplayName,
  formatJidAsPhone,
  getQuotedPreview,
  getQuotedReconstruction,
} from "../storage/messages.ts";
import { deleteSession } from "../storage/session.ts";
import {
  type StageInput,
  discardDraft,
  getDraft,
  listDrafts,
  stageDraft,
  updateDraft,
  DraftSchemaError,
} from "../storage/drafts.ts";
import { reserveSend, SEND_ERR } from "../storage/audit.ts";
import { readSettings, SettingsError } from "../settings.ts";

const RPC_ERR = {
  PEER_NOT_AUTHORIZED: -32001,
  METHOD_NOT_FOUND: -32601,
  INVALID_PARAMS: -32602,
  INTERNAL: -32603,
  NOT_CONNECTED: -32010,
  // Send-path errors map to specific codes so the MCP layer can
  // surface a stable error name to Claude without parsing strings.
  PENDING_APPROVAL: -32020,
  MIN_AGE_NOT_REACHED: -32021,
  INTER_SEND_TOO_FAST: -32022,
  BURST_LIMIT_HIT: -32023,
  DAILY_CAP_HIT: -32024,
  SEND_FAILED: -32025,
  DRAFT_NOT_FOUND: -32026,
  SETTINGS_ERROR: -32027,
};

interface RpcRequest {
  jsonrpc: "2.0";
  id?: string | number | null;
  method: string;
  params?: unknown;
}

interface RpcResponse {
  jsonrpc: "2.0";
  id: string | number | null;
  result?: unknown;
  error?: { code: number; message: string; data?: unknown };
}

interface RpcNotification {
  jsonrpc: "2.0";
  method: string;
  params?: unknown;
}

export interface RpcServer {
  stop(): Promise<void>;
}

export async function startRpcServer(connection: WhatsAppConnection): Promise<RpcServer> {
  // Dev-mode safeguard: refuse to honor WHATSAPP_MCP_DEV in a signed prod binary.
  const safeguard = refuseDevModeInProduction();
  if (!safeguard.allow) {
    throw new Error(safeguard.reason ?? "Dev-mode refused in production");
  }

  // Clean any stale socket from a previous crash.
  if (existsSync(PATHS.daemonSock)) {
    try { unlinkSync(PATHS.daemonSock); } catch { /* ignore */ }
  }

  type Sub = { id: string; channel: "qr" | "state"; sock: Socket };
  const subs = new Map<string, Sub>();

  const broadcast = (channel: "qr" | "state", payload: unknown) => {
    const note: RpcNotification = { jsonrpc: "2.0", method: `${channel}.update`, params: payload };
    const line = JSON.stringify(note) + "\n";
    for (const sub of subs.values()) {
      // qr subscribers also receive state.update broadcasts: the
      // pairing flow inherently cares about the post-scan transition
      // (so the view can auto-dismiss on "connected") AND about the
      // post-pair restartRequired cycle (so the view can stay on
      // "pairingHandshake" rather than time out reading and surface a
      // spurious "connection dropped" error). The contract is
      // documented in menubar/Sources/.../WhatsAppQRSession.swift.
      const wantsThis =
        sub.channel === channel ||
        (channel === "state" && sub.channel === "qr");
      if (wantsThis) {
        try { sub.sock.write(line); } catch { /* peer gone */ }
      }
    }
  };

  connection.on("qr", (qr) => broadcast("qr", { qr }));
  connection.on("state", (s) => broadcast("state", { state: s }));
  connection.on("paired", (info) => broadcast("state", { state: "connected", ...info }));

  const server: Server = createServer();

  server.on("connection", async (sock) => {
    const auth = await authenticatePeer(sock);
    if (!auth.authorized) {
      const err: RpcResponse = {
        jsonrpc: "2.0",
        id: null,
        error: { code: RPC_ERR.PEER_NOT_AUTHORIZED, message: auth.reason ?? "peer not authorized" },
      };
      try { sock.write(JSON.stringify(err) + "\n"); } catch { /* ignore */ }
      sock.end();
      return;
    }

    let buf = "";
    sock.on("data", (chunk) => {
      buf += chunk.toString("utf8");
      let nl: number;
      while ((nl = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, nl);
        buf = buf.slice(nl + 1);
        if (line.trim().length === 0) continue;
        let req: RpcRequest;
        try {
          req = JSON.parse(line) as RpcRequest;
        } catch {
          continue; // ignore malformed lines
        }
        void handle(req, sock, subs, connection).then((resp) => {
          if (resp == null) return; // notifications get no response
          try { sock.write(JSON.stringify(resp) + "\n"); } catch { /* peer gone */ }
        });
      }
    });

    sock.on("close", () => {
      // Drop any subscriptions held by this socket.
      for (const [id, sub] of subs.entries()) {
        if (sub.sock === sock) subs.delete(id);
      }
    });
    sock.on("error", () => { /* ignore */ });
  });

  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(PATHS.daemonSock, () => {
      // Restrict the socket to owner only.
      try {
        // chmod the socket file itself. node:net binds before this runs.
        // eslint-disable-next-line @typescript-eslint/no-require-imports
        const { chmodSync } = require("node:fs") as typeof import("node:fs");
        chmodSync(PATHS.daemonSock, 0o600);
      } catch { /* ignore */ }
      resolve();
    });
  });

  return {
    stop: async () => {
      await new Promise<void>((resolve) => server.close(() => resolve()));
      try { unlinkSync(PATHS.daemonSock); } catch { /* ignore */ }
    },
  };
}

async function handle(
  req: RpcRequest,
  sock: Socket,
  subs: Map<string, { id: string; channel: "qr" | "state"; sock: Socket }>,
  connection: WhatsAppConnection,
): Promise<RpcResponse | null> {
  const id = req.id ?? null;
  try {
    switch (req.method) {
      case "getConnectionStatus": {
        return ok(id, { state: connection.getState(), me: connection.getMe() });
      }
      case "getThreads": {
        const p = (req.params ?? {}) as { since?: number; contact_filter?: string; limit?: number };
        return ok(id, { threads: listThreads(p) });
      }
      case "getThread": {
        const p = req.params as { thread_jid: string; before_ts?: number; limit?: number };
        if (typeof p?.thread_jid !== "string") return err(id, RPC_ERR.INVALID_PARAMS, "thread_jid required");
        return ok(id, { messages: getThreadMessages(p) });
      }
      case "searchMessages": {
        const p = req.params as { query: string; since?: number; contact_filter?: string; limit?: number };
        if (typeof p?.query !== "string" || p.query.length < 2) return err(id, RPC_ERR.INVALID_PARAMS, "query must be ≥2 chars");
        if (p.since == null && (p.contact_filter == null || p.contact_filter.length === 0)) {
          return err(id, RPC_ERR.INVALID_PARAMS, "either `since` or `contact_filter` is required");
        }
        return ok(id, { messages: searchMessages(p) });
      }
      case "getMessageFull": {
        const p = req.params as { thread_jid: string; message_id: string };
        if (typeof p?.thread_jid !== "string" || typeof p?.message_id !== "string") {
          return err(id, RPC_ERR.INVALID_PARAMS, "thread_jid and message_id required");
        }
        const body = getMessageFull(p.thread_jid, p.message_id);
        return ok(id, { body });
      }
      case "subscribe": {
        const p = req.params as { channel: "qr" | "state" };
        if (p?.channel !== "qr" && p?.channel !== "state") {
          return err(id, RPC_ERR.INVALID_PARAMS, "channel must be 'qr' or 'state'");
        }
        const subId = `sub_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
        subs.set(subId, { id: subId, channel: p.channel, sock });
        // Immediately push current state so subscribers don't wait for the next event.
        if (p.channel === "state") {
          const note: RpcNotification = { jsonrpc: "2.0", method: "state.update", params: { state: connection.getState() } };
          sock.write(JSON.stringify(note) + "\n");
        } else if (p.channel === "qr") {
          const qr = connection.getQr();
          if (qr != null) {
            const note: RpcNotification = { jsonrpc: "2.0", method: "qr.update", params: { qr } };
            sock.write(JSON.stringify(note) + "\n");
          }
        }
        return ok(id, { subscription_id: subId });
      }
      case "unsubscribe": {
        const p = req.params as { subscription_id: string };
        subs.delete(p?.subscription_id);
        return ok(id, { ok: true });
      }
      case "unlinkAndReset": {
        deleteSession();
        try { unlinkSync(PATHS.loggedOutSentinel); } catch { /* ignore */ }
        // Reply BEFORE kicking off the async reconnect — Baileys's
        // connect path takes a couple seconds (auth state + version
        // fetch) and the menubar shouldn't be blocked on it.
        setImmediate(() => {
          connection.start().catch((e) => {
            process.stderr.write(`unlinkAndReset → connection.start() failed: ${(e as Error).message}\n`);
          });
        });
        return ok(id, { ok: true, note: "Session wiped; daemon reconnecting." });
      }
      // ──────────────────────────────────────────────────────────────────
      // Phase 2 — Draft + Send
      // ──────────────────────────────────────────────────────────────────
      case "stageDraft": {
        const p = req.params as StageInput;
        if (typeof p?.to_handle !== "string" || typeof p?.body !== "string") {
          return err(id, RPC_ERR.INVALID_PARAMS, "to_handle and body required");
        }
        if (p.body.length === 0) {
          return err(id, RPC_ERR.INVALID_PARAMS, "body must not be empty");
        }
        if (p.quoted_message_id != null && typeof p.quoted_message_id !== "string") {
          return err(id, RPC_ERR.INVALID_PARAMS, "quoted_message_id must be a string");
        }
        // Resolve the quoted message into a stage-time preview snapshot so the
        // menubar can render "Replying to …" without its own daemon lookup.
        // Null when the message isn't cached — the draft still carries
        // quoted_message_id and the reply is reconstructed at send time.
        const quotedPreview =
          p.quoted_message_id != null && p.quoted_message_id.length > 0
            ? getQuotedPreview(p.to_handle, p.quoted_message_id)
            : null;
        // Pull last 5 messages from messages.db as the context snapshot.
        let ctx: ReturnType<typeof getThreadMessages> = [];
        let diag: "no_thread_match" | "thread_empty" | "error" | null = null;
        try {
          ctx = getThreadMessages({ thread_jid: p.to_handle, limit: 5 });
          if (ctx.length === 0) diag = "thread_empty";
        } catch {
          diag = "error";
        }
        // Resolve a recipient display name at stage time. Caller may have
        // pre-resolved one (an MCP middleware lookup); otherwise pull
        // from contacts/threads tables; otherwise pretty-format the JID.
        // Group JIDs always fall through to thread name → raw JID.
        let resolvedName: string | null = p.to_handle_name ?? null;
        if (resolvedName == null) {
          try {
            resolvedName = getContactDisplayName(p.to_handle);
          } catch { /* DB hiccup — fall through to phone format */ }
        }
        if (resolvedName == null && !p.to_handle.endsWith("@g.us")) {
          // Self-send special case: if the user is messaging themselves,
          // show "You" rather than their own phone number — matches what
          // every other chat app does for the self-thread.
          const meJid = connection.getMe().jid;
          if (meJid != null && p.to_handle === meJid) {
            resolvedName = "You";
          } else {
            resolvedName = formatJidAsPhone(p.to_handle);
          }
        }
        const draft = stageDraft({
          to_handle: p.to_handle,
          to_handle_name: resolvedName,
          body: p.body,
          source: p.source,
          context_messages: ctx.map((m) => ({
            message_id: m.message_id,
            // v0.3.2: write the menubar-side field names directly so
            // ContextMessage Codable parses without compat fallback.
            // sender_name resolved at stage time using the same helper
            // the read-path tools use (gets @lid mapping for free).
            sender_handle: m.sender_jid,
            sender_name: m.from_me ? null : (() => {
              try {
                return getContactDisplayName(m.sender_jid);
              } catch {
                return null;
              }
            })(),
            from_me: m.from_me,
            sent_at: new Date(m.ts).toISOString(),
            body: m.body,
          })),
          context_diagnostic: diag,
          induced_by_unknown_contact: p.induced_by_unknown_contact ?? false,
          quoted_message_id: p.quoted_message_id ?? null,
          quoted_preview: quotedPreview,
        });
        return ok(id, { draft });
      }
      case "getDrafts": {
        const r = listDrafts();
        return ok(id, r);
      }
      case "getDraft": {
        const p = req.params as { draft_id: string };
        if (typeof p?.draft_id !== "string") return err(id, RPC_ERR.INVALID_PARAMS, "draft_id required");
        try {
          const draft = getDraft(p.draft_id);
          if (draft == null) return err(id, RPC_ERR.DRAFT_NOT_FOUND, `no draft ${p.draft_id}`);
          return ok(id, { draft });
        } catch (e) {
          if (e instanceof DraftSchemaError) return err(id, RPC_ERR.INVALID_PARAMS, e.message);
          throw e;
        }
      }
      case "discardDraft": {
        const p = req.params as { draft_id: string };
        if (typeof p?.draft_id !== "string") return err(id, RPC_ERR.INVALID_PARAMS, "draft_id required");
        try {
          const existed = discardDraft(p.draft_id);
          return ok(id, { ok: true, existed });
        } catch (e) {
          if (e instanceof DraftSchemaError) return err(id, RPC_ERR.INVALID_PARAMS, e.message);
          throw e;
        }
      }
      case "approveDraft": {
        // Called by the menu bar app's hold-to-fire BEFORE sendDraft.
        // Also callable from MCP when settings.require_approval = false
        // (the MCP tool side handles that gate).
        const p = req.params as { draft_id: string };
        if (typeof p?.draft_id !== "string") return err(id, RPC_ERR.INVALID_PARAMS, "draft_id required");
        try {
          const d = updateDraft(p.draft_id, { approval_state: "approved" });
          return ok(id, { draft: d });
        } catch (e) {
          if (e instanceof DraftSchemaError) return err(id, RPC_ERR.INVALID_PARAMS, e.message);
          throw e;
        }
      }
      case "sendDraft": {
        const p = req.params as { draft_id: string };
        if (typeof p?.draft_id !== "string") return err(id, RPC_ERR.INVALID_PARAMS, "draft_id required");
        return await handleSendDraft(id, p.draft_id, connection);
      }
      default:
        return err(id, RPC_ERR.METHOD_NOT_FOUND, `Method not found: ${req.method}`);
    }
  } catch (e) {
    return err(id, RPC_ERR.INTERNAL, (e as Error).message);
  }
}

function ok(id: string | number | null, result: unknown): RpcResponse {
  return { jsonrpc: "2.0", id, result };
}
function err(id: string | number | null, code: number, message: string): RpcResponse {
  return { jsonrpc: "2.0", id, error: { code, message } };
}

/** SHA-256 of the body, hex-encoded. Audit-only — body itself never logged. */
function bodyHash(body: string): string {
  return new Bun.CryptoHasher("sha256").update(body).digest("hex");
}

async function handleSendDraft(
  id: string | number | null,
  draftId: string,
  connection: WhatsAppConnection,
): Promise<RpcResponse> {
  // 1. Settings (fail-closed on any error).
  let settings;
  try {
    settings = readSettings();
  } catch (e) {
    if (e instanceof SettingsError) return err(id, RPC_ERR.SETTINGS_ERROR, e.message);
    throw e;
  }

  // 2. Load draft.
  let draft;
  try {
    draft = getDraft(draftId);
  } catch (e) {
    if (e instanceof DraftSchemaError) return err(id, RPC_ERR.INVALID_PARAMS, e.message);
    throw e;
  }
  if (draft == null) return err(id, RPC_ERR.DRAFT_NOT_FOUND, `no draft ${draftId}`);
  if (draft.sent_at != null) return err(id, RPC_ERR.INVALID_PARAMS, "draft already sent");

  // 3. Approval gate.
  if (draft.approval_state !== "approved") {
    return err(id, RPC_ERR.PENDING_APPROVAL, "draft has not been approved");
  }

  // 4. Min staged age.
  const stagedMs = Date.parse(draft.staged_at);
  if (Number.isFinite(stagedMs)) {
    const age = Date.now() - stagedMs;
    if (age < settings.min_staged_age_ms) {
      return err(id, RPC_ERR.MIN_AGE_NOT_REACHED, `staged ${age}ms ago, min ${settings.min_staged_age_ms}ms`);
    }
  }

  // 5. Atomic cap + burst + inter-send reservation.
  const reservation = reserveSend({
    draft_id: draft.id,
    to_handle: draft.to_handle,
    body_sha256: bodyHash(draft.body),
    settings,
  });
  if (!reservation.ok) {
    switch (reservation.error) {
      case SEND_ERR.DAILY_CAP_HIT: return err(id, RPC_ERR.DAILY_CAP_HIT, reservation.detail);
      case SEND_ERR.BURST_LIMIT_HIT: return err(id, RPC_ERR.BURST_LIMIT_HIT, reservation.detail);
      case SEND_ERR.INTER_SEND_TOO_FAST: return err(id, RPC_ERR.INTER_SEND_TOO_FAST, reservation.detail);
    }
  }

  // 6. Inter-send jitter (±500ms) — burned AFTER reservation so the slot
  // is already counted but Meta's anti-bot heuristics see staggered timing.
  const jitterMs = Math.floor((Math.random() * 2 - 1) * 500);
  if (jitterMs > 0) {
    await new Promise<void>((resolve) => setTimeout(resolve, jitterMs));
  }

  // 7. Baileys send.
  try {
    // Reply-draft: reconstruct the quoted message from the cache so Baileys
    // threads the reply. Null (quoted message no longer cached) degrades
    // gracefully to a normal message.
    const quoted =
      draft.quoted_message_id != null
        ? getQuotedReconstruction(draft.to_handle, draft.quoted_message_id)
        : null;
    const result = await connection.sendText(draft.to_handle, draft.body, quoted);
    reservation.commit("ok");
    const sent_at = new Date().toISOString();
    try { updateDraft(draft.id, { sent_at }); } catch { /* draft sweep handles cleanup */ }
    return ok(id, {
      ok: true,
      draft_id: draft.id,
      message_id: result.message_id,
      sent_at,
    });
  } catch (e) {
    reservation.commit("send_failed");
    return err(id, RPC_ERR.SEND_FAILED, (e as Error).message);
  }
}
