import { describe, test, expect, beforeAll, beforeEach, afterAll, afterEach } from "bun:test";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";

import * as drafts from "./drafts.ts";
import { _setContactsForTesting, _resetContactsCache, resolveHandle } from "../chatdb/contacts.ts";

// Use the explicit test seam (`_setDraftsDirForTesting`). The earlier
// approach of overriding `process.env.HOME` doesn't work on macOS —
// `os.homedir()` uses passwd lookup by effective UID and ignores the
// JS-level override, so tests silently leaked into the real
// `~/.imessage-mcp/drafts` AND wiped its contents in beforeEach.
const tmpHome = mkdtempSync(join(tmpdir(), "imessage-mcp-test-"));
const tmpDraftsDir = join(tmpHome, ".imessage-mcp", "drafts");

beforeAll(() => {
  drafts._setDraftsDirForTesting(tmpDraftsDir);
});

afterAll(() => {
  drafts._setDraftsDirForTesting(null);
  rmSync(tmpHome, { recursive: true, force: true });
});

beforeEach(() => {
  // Clear test drafts between tests so listDrafts assertions stay
  // deterministic. Safe to rmSync now — this is the tmp dir, not the
  // user's real drafts.
  rmSync(tmpDraftsDir, { recursive: true, force: true });
});

describe("stageDraft / getDraft / discardDraft", () => {
  test("stage writes a draft with sent_at: null and 0600 perms", () => {
    const { draft, path } = drafts.stageDraft({ to_handle: "+14155551234", body: "hi" });
    expect(draft.sent_at).toBeNull();
    expect(draft.send_service).toBeNull();
    expect(draft.source).toBeNull();
    expect(draft.to_handle).toBe("+14155551234");
    expect(draft.body).toBe("hi");
    expect(path.endsWith(`${draft.id}.json`)).toBe(true);
    expect(path.startsWith(tmpDraftsDir)).toBe(true);
  });

  test("stage with source records the provenance label", () => {
    const { draft } = drafts.stageDraft({
      to_handle: "+14155551234",
      body: "hi",
      source: "Claude Code / unit test",
    });
    expect(draft.source).toBe("Claude Code / unit test");
  });

  test("getDraft returns the staged draft", () => {
    const { draft } = drafts.stageDraft({ to_handle: "+14155551234", body: "hi" });
    const fetched = drafts.getDraft(draft.id);
    expect(fetched?.id).toBe(draft.id);
    expect(fetched?.body).toBe("hi");
  });

  test("getDraft returns null for unknown id", () => {
    expect(drafts.getDraft(randomUUID())).toBeNull();
  });

  test("listDrafts returns newest-first", () => {
    const a = drafts.stageDraft({ to_handle: "+14155551111", body: "a" });
    // Tiny gap so the file mtimes differ enough to sort.
    Bun.sleepSync(15);
    const b = drafts.stageDraft({ to_handle: "+14155552222", body: "b" });
    const list = drafts.listDrafts(10);
    expect(list[0]!.id).toBe(b.draft.id);
    expect(list[1]!.id).toBe(a.draft.id);
  });

  test("discardDraft removes the file and getDraft returns null after", () => {
    const { draft } = drafts.stageDraft({ to_handle: "+14155551234", body: "hi" });
    expect(drafts.discardDraft(draft.id)).toBe(true);
    expect(drafts.getDraft(draft.id)).toBeNull();
  });

  test("discardDraft returns false for unknown id", () => {
    expect(drafts.discardDraft(randomUUID())).toBe(false);
  });
});

describe("markDraftSent", () => {
  test("sets sent_at + send_service and persists to disk", () => {
    const { draft } = drafts.stageDraft({ to_handle: "+14155551234", body: "hi" });
    const updated = drafts.markDraftSent(draft.id, "2026-05-13T00:00:00.000Z", "iMessage");
    expect(updated?.sent_at).toBe("2026-05-13T00:00:00.000Z");
    expect(updated?.send_service).toBe("iMessage");

    const fetched = drafts.getDraft(draft.id);
    expect(fetched?.sent_at).toBe("2026-05-13T00:00:00.000Z");
    expect(fetched?.send_service).toBe("iMessage");
  });

  test("preserves source through mark-sent", () => {
    const { draft } = drafts.stageDraft({
      to_handle: "+14155551234",
      body: "hi",
      source: "ci test",
    });
    const updated = drafts.markDraftSent(draft.id, "2026-05-13T00:00:00.000Z", "SMS");
    expect(updated?.source).toBe("ci test");
  });

  test("returns null for unknown id", () => {
    expect(drafts.markDraftSent(randomUUID(), "2026-05-13T00:00:00.000Z", "iMessage")).toBeNull();
  });
});

describe("normalizeDraft backward-compat", () => {
  test("reads a pre-source / pre-sent_at format draft and backfills nulls", () => {
    // Hand-write a draft in the earliest schema (before sent_at,
    // send_service, source). The test seam ensures this lands in the
    // tmpdir, not the real drafts dir.
    const id = randomUUID();
    // Trigger ensureDir by staging once.
    drafts.stageDraft({ to_handle: "+14155550000", body: "seed" });
    writeFileSync(join(tmpDraftsDir, `${id}.json`), JSON.stringify({
      id,
      to_handle: "+14155551234",
      body: "from v0",
      in_reply_to_thread_id: null,
      staged_at: "2026-05-01T00:00:00Z",
    }, null, 2));
    const fetched = drafts.getDraft(id);
    expect(fetched?.sent_at).toBeNull();
    expect(fetched?.send_service).toBeNull();
    expect(fetched?.source).toBeNull();
    expect(fetched?.body).toBe("from v0");
  });
});

describe("to_handle_name resolution", () => {
  afterEach(() => {
    _resetContactsCache();
  });

  test("stage with a handle that resolves → to_handle_name populated", () => {
    // canonHandle("+14155551234") = "4155551234" (last 10 digits)
    _setContactsForTesting(new Map([["4155551234", "Alice Smith"]]), []);
    const name = resolveHandle("+14155551234");
    const { draft } = drafts.stageDraft({ to_handle: "+14155551234", to_handle_name: name, body: "hi" });
    expect(draft.to_handle_name).toBe("Alice Smith");
    // Persists through getDraft round-trip.
    expect(drafts.getDraft(draft.id)?.to_handle_name).toBe("Alice Smith");
  });

  test("stage with a handle that doesn't resolve → to_handle_name null", () => {
    _setContactsForTesting(new Map(), []);
    const name = resolveHandle("+14155559999");
    const { draft } = drafts.stageDraft({ to_handle: "+14155559999", to_handle_name: name, body: "hi" });
    expect(draft.to_handle_name).toBeNull();
    expect(drafts.getDraft(draft.id)?.to_handle_name).toBeNull();
  });

  test("non-canonical phone form still matches via canonHandle", () => {
    // Both "+1 (404) 561-0417" and "+14045610417" canonicalize to "4045610417".
    _setContactsForTesting(new Map([["4045610417", "Bob Jones"]]), []);
    expect(resolveHandle("+1 (404) 561-0417")).toBe("Bob Jones");
    expect(resolveHandle("+14045610417")).toBe("Bob Jones");
  });

  test("normalizeDraft backward-compat: draft without to_handle_name decodes with null", () => {
    const id = randomUUID();
    drafts.stageDraft({ to_handle: "+14155550000", body: "seed" });
    writeFileSync(join(tmpDraftsDir, `${id}.json`), JSON.stringify({
      id,
      to_handle: "+14155551234",
      body: "legacy draft",
      in_reply_to_thread_id: null,
      staged_at: "2026-05-01T00:00:00Z",
    }, null, 2));
    const fetched = drafts.getDraft(id);
    expect(fetched?.to_handle_name).toBeNull();
    expect(fetched?.body).toBe("legacy draft");
  });
});
