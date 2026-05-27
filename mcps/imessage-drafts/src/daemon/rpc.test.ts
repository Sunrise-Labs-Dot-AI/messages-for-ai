// Tests for the daemon RPC layer: the dispatch/validation logic (handle())
// exercised directly, plus the client's daemon-unavailable behavior. The full
// socket + peer-auth round-trip is covered by the live menu-bar integration,
// not here (it needs a signed binary + a running daemon).

import { test, expect, describe, beforeAll, afterAll } from "bun:test";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { handle } from "./server.ts";
import { callDaemon, DaemonUnavailableError } from "./rpc-client.ts";

describe("daemon RPC dispatch (handle)", () => {
  test("chatDbDiagnostic returns a diagnostic (never throws)", () => {
    const r = handle({ jsonrpc: "2.0", id: 1, method: "chatDbDiagnostic" });
    expect(r.error).toBeUndefined();
    expect((r.result as { open_status?: string }).open_status).toBeDefined();
  });

  test("health returns chatdb + addressbook + contacts_load", () => {
    const r = handle({ jsonrpc: "2.0", id: 2, method: "health" });
    expect(r.error).toBeUndefined();
    const res = r.result as Record<string, unknown>;
    expect(res.chatdb).toBeDefined();
    expect(res.addressbook).toBeDefined();
    expect(res.contacts_load).toBeDefined();
  });

  test("unknown method → METHOD_NOT_FOUND (-32601)", () => {
    const r = handle({ jsonrpc: "2.0", id: 3, method: "definitelyNotAMethod" });
    expect(r.error?.code).toBe(-32601);
  });

  test("probeHandle canonicalizes; missing handle → INVALID_PARAMS", () => {
    const ok = handle({
      jsonrpc: "2.0", id: 4, method: "probeHandle",
      params: { handle: "+1 (415) 555-1234" },
    });
    expect(ok.error).toBeUndefined();
    // resolved_name depends on the local Contacts sidecar (not asserted);
    // canonicalization is deterministic.
    expect((ok.result as { canonical?: string }).canonical).toBe("4155551234");

    const bad = handle({ jsonrpc: "2.0", id: 5, method: "probeHandle", params: {} });
    expect(bad.error?.code).toBe(-32602);
  });

  test("listThreads without limit → INVALID_PARAMS (-32602)", () => {
    const r = handle({ jsonrpc: "2.0", id: 6, method: "listThreads", params: {} });
    expect(r.error?.code).toBe(-32602);
  });

  test("getThread without threadId → INVALID_PARAMS", () => {
    const r = handle({ jsonrpc: "2.0", id: 7, method: "getThread", params: { limit: 10 } });
    expect(r.error?.code).toBe(-32602);
  });

  test("searchMessages with <2-char query → INVALID_PARAMS", () => {
    const r = handle({
      jsonrpc: "2.0", id: 8, method: "searchMessages",
      params: { query: "a", limit: 5 },
    });
    expect(r.error?.code).toBe(-32602);
  });

  test("recentContext without limit → INVALID_PARAMS", () => {
    const r = handle({ jsonrpc: "2.0", id: 9, method: "recentContext", params: {} });
    expect(r.error?.code).toBe(-32602);
  });
});

describe("rpc-client (daemon unavailable)", () => {
  const prev = process.env.MESSAGES_MCP_HOME;
  beforeAll(() => {
    // Point at a tmpdir with no daemon.sock so connectWithTimeout's
    // existsSync gate fails fast.
    process.env.MESSAGES_MCP_HOME = mkdtempSync(join(tmpdir(), "imsg-rpc-test-"));
  });
  afterAll(() => {
    if (prev === undefined) delete process.env.MESSAGES_MCP_HOME;
    else process.env.MESSAGES_MCP_HOME = prev;
  });

  test("callDaemon rejects with DaemonUnavailableError when the socket is missing", async () => {
    await expect(callDaemon("chatDbDiagnostic")).rejects.toBeInstanceOf(DaemonUnavailableError);
  });
});
