// Unix-socket JSON-RPC server for the iMessage daemon. Speaks
// newline-delimited JSON-RPC 2.0 (same wire format as the WhatsApp daemon).
// Single source of truth for what the MCP binary can ask the daemon to do.
//
// All methods are READ-ONLY chat.db / AddressBook lookups — the daemon holds
// Full Disk Access (inherited from the menu-bar app that launches it) and
// performs the reads the Claude-launched MCP can't. Sending + draft files
// stay in the MCP (AppleScript + local JSON, no FDA needed).
//
// Methods:
//   - chatDbDiagnostic()                       → ChatDbDiagnostic
//   - health()                                 → { chatdb, addressbook, contacts_load }
//   - probeHandle({ handle })                  → { input, canonical, resolved_name }
//   - listThreads({ limit, sinceIso?, beforeIso?, contactFilter? })
//   - getThread({ threadId, limit, beforeIso? })
//   - searchMessages({ query, limit, sinceIso?, contactFilter? })
//   - recentContext({ recipientHandle?, threadId?, limit })

import { createServer, type Server, type Socket } from "node:net";
import { existsSync, unlinkSync, chmodSync } from "node:fs";

import { PATHS } from "./paths.ts";
import { authenticatePeer, refuseDevModeInProduction } from "./peer-auth.ts";
import {
  listThreads,
  getThreadMessages,
  searchMessages,
  recentContextForRecipient,
} from "../chatdb/queries.ts";
import { getChatDbDiagnostic } from "../chatdb/open.ts";
import {
  getAddressBookSqliteDiagnostic,
  getContactsLoadDiagnostic,
  canonHandlePublic,
  resolveHandle,
} from "../chatdb/contacts.ts";

const RPC_ERR = {
  PEER_NOT_AUTHORIZED: -32001,
  METHOD_NOT_FOUND: -32601,
  INVALID_PARAMS: -32602,
  INTERNAL: -32603,
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
  error?: { code: number; message: string };
}

export interface RpcServer {
  stop(): Promise<void>;
}

export async function startRpcServer(): Promise<RpcServer> {
  const safeguard = refuseDevModeInProduction();
  if (!safeguard.allow) {
    throw new Error(safeguard.reason ?? "Dev-mode refused in production");
  }

  // Clean any stale socket from a previous crash.
  if (existsSync(PATHS.daemonSock)) {
    try { unlinkSync(PATHS.daemonSock); } catch { /* ignore */ }
  }

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
      // Defense-in-depth: a peer that never sends a newline must not grow buf
      // unbounded and OOM the FDA-holding daemon. RPC requests are tiny.
      if (buf.length > 1_000_000) { sock.destroy(); return; }
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
        const resp = handle(req);
        try { sock.write(JSON.stringify(resp) + "\n"); } catch { /* peer gone */ }
      }
    });
    sock.on("error", () => { /* ignore */ });
  });

  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(PATHS.daemonSock, () => {
      try { chmodSync(PATHS.daemonSock, 0o600); } catch { /* ignore */ }
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

// Exported for unit testing the dispatch/validation logic directly, without
// standing up a socket + peer-auth. Production callers go through the socket.
export function handle(req: RpcRequest): RpcResponse {
  const id = req.id ?? null;
  try {
    switch (req.method) {
      case "chatDbDiagnostic": {
        return ok(id, getChatDbDiagnostic());
      }
      case "health": {
        return ok(id, {
          chatdb: getChatDbDiagnostic(),
          addressbook: getAddressBookSqliteDiagnostic(),
          contacts_load: getContactsLoadDiagnostic(),
        });
      }
      case "probeHandle": {
        const p = req.params as { handle?: unknown };
        if (typeof p?.handle !== "string" || p.handle.length === 0) {
          return err(id, RPC_ERR.INVALID_PARAMS, "handle (non-empty string) required");
        }
        return ok(id, {
          input: p.handle,
          canonical: canonHandlePublic(p.handle),
          resolved_name: resolveHandle(p.handle),
        });
      }
      case "listThreads": {
        const p = (req.params ?? {}) as {
          limit?: unknown; sinceIso?: unknown; beforeIso?: unknown; contactFilter?: unknown;
        };
        if (!Number.isInteger(p.limit) || (p.limit as number) < 1 || (p.limit as number) > 500) {
          return err(id, RPC_ERR.INVALID_PARAMS, "limit must be an integer 1..500");
        }
        return ok(id, listThreads({
          limit: p.limit,
          sinceIso: typeof p.sinceIso === "string" ? p.sinceIso : undefined,
          beforeIso: typeof p.beforeIso === "string" ? p.beforeIso : undefined,
          contactFilter: typeof p.contactFilter === "string" ? p.contactFilter : undefined,
        }));
      }
      case "getThread": {
        const p = (req.params ?? {}) as { threadId?: unknown; limit?: unknown; beforeIso?: unknown };
        if (!Number.isInteger(p.threadId) || (p.threadId as number) < 1) return err(id, RPC_ERR.INVALID_PARAMS, "threadId must be a positive integer");
        if (!Number.isInteger(p.limit) || (p.limit as number) < 1 || (p.limit as number) > 500) {
          return err(id, RPC_ERR.INVALID_PARAMS, "limit must be an integer 1..500");
        }
        return ok(id, getThreadMessages({
          threadId: p.threadId,
          limit: p.limit,
          beforeIso: typeof p.beforeIso === "string" ? p.beforeIso : undefined,
        }));
      }
      case "searchMessages": {
        const p = (req.params ?? {}) as {
          query?: unknown; limit?: unknown; sinceIso?: unknown; contactFilter?: unknown;
        };
        if (typeof p.query !== "string" || p.query.length < 2) return err(id, RPC_ERR.INVALID_PARAMS, "query (>=2 chars) required");
        if (!Number.isInteger(p.limit) || (p.limit as number) < 1 || (p.limit as number) > 500) {
          return err(id, RPC_ERR.INVALID_PARAMS, "limit must be an integer 1..500");
        }
        return ok(id, searchMessages({
          query: p.query,
          limit: p.limit,
          sinceIso: typeof p.sinceIso === "string" ? p.sinceIso : undefined,
          contactFilter: typeof p.contactFilter === "string" ? p.contactFilter : undefined,
        }));
      }
      case "recentContext": {
        const p = (req.params ?? {}) as { recipientHandle?: unknown; threadId?: unknown; limit?: unknown };
        if (!Number.isInteger(p.limit) || (p.limit as number) < 1 || (p.limit as number) > 500) {
          return err(id, RPC_ERR.INVALID_PARAMS, "limit must be an integer 1..500");
        }
        return ok(id, recentContextForRecipient({
          recipientHandle: typeof p.recipientHandle === "string" ? p.recipientHandle : undefined,
          threadId: typeof p.threadId === "number" ? p.threadId : undefined,
          limit: p.limit,
        }));
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
