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
} from "../storage/messages.ts";
import { deleteSession } from "../storage/session.ts";

const RPC_ERR = {
  PEER_NOT_AUTHORIZED: -32001,
  METHOD_NOT_FOUND: -32601,
  INVALID_PARAMS: -32602,
  INTERNAL: -32603,
  NOT_CONNECTED: -32010,
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
      if (sub.channel === channel) {
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
        return ok(id, { state: connection.getState() });
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
        // TODO(security): when peer-auth lands, gate this to menu-bar bundle only.
        deleteSession();
        try { unlinkSync(PATHS.loggedOutSentinel); } catch { /* ignore */ }
        return ok(id, { ok: true, note: "Session deleted. Restart daemon to re-pair." });
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
