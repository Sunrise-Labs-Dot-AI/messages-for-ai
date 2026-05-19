// Thin JSON-RPC 2.0 client over the daemon's Unix socket. Used by the
// MCP stdio binary to talk to the daemon. Single-shot request/response;
// notifications (server-pushed events) are dropped here — the menu bar
// app handles subscriptions, not the MCP binary.

import { Socket, connect } from "node:net";
import { existsSync } from "node:fs";

import { PATHS } from "../paths.ts";

const CONNECT_TIMEOUT_MS = 2000;
const REQUEST_TIMEOUT_MS = 10_000;

interface RpcResponse {
  jsonrpc: "2.0";
  id: string | number | null;
  result?: unknown;
  error?: { code: number; message: string };
}

export class DaemonUnavailableError extends Error {
  constructor() {
    super("WhatsApp daemon not running — check menu bar app (or run scripts/install.sh)");
  }
}

export class DaemonRpcError extends Error {
  constructor(public code: number, message: string) {
    super(message);
  }
}

function connectWithTimeout(): Promise<Socket> {
  return new Promise((resolve, reject) => {
    if (!existsSync(PATHS.daemonSock)) {
      reject(new DaemonUnavailableError());
      return;
    }
    const sock = connect(PATHS.daemonSock);
    const timer = setTimeout(() => {
      sock.destroy();
      reject(new DaemonUnavailableError());
    }, CONNECT_TIMEOUT_MS);
    sock.once("connect", () => { clearTimeout(timer); resolve(sock); });
    sock.once("error", () => { clearTimeout(timer); reject(new DaemonUnavailableError()); });
  });
}

export async function callDaemon<T>(method: string, params?: unknown): Promise<T> {
  const sock = await connectWithTimeout();
  const id = Math.floor(Math.random() * 1e9);
  const req = { jsonrpc: "2.0" as const, id, method, params };

  return new Promise<T>((resolve, reject) => {
    let buf = "";
    const timer = setTimeout(() => {
      sock.destroy();
      reject(new Error(`Daemon RPC ${method} timed out after ${REQUEST_TIMEOUT_MS}ms`));
    }, REQUEST_TIMEOUT_MS);

    sock.on("data", (chunk) => {
      buf += chunk.toString("utf8");
      let nl: number;
      while ((nl = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, nl);
        buf = buf.slice(nl + 1);
        if (line.trim().length === 0) continue;
        let resp: RpcResponse;
        try { resp = JSON.parse(line) as RpcResponse; } catch { continue; }
        // Drop notifications (no id).
        if (resp.id == null) continue;
        if (resp.id !== id) continue;
        clearTimeout(timer);
        sock.end();
        if (resp.error != null) {
          reject(new DaemonRpcError(resp.error.code, resp.error.message));
        } else {
          resolve(resp.result as T);
        }
        return;
      }
    });
    sock.on("error", (err) => {
      clearTimeout(timer);
      reject(err);
    });
    sock.write(JSON.stringify(req) + "\n");
  });
}
