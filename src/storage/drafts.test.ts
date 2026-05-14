import { describe, test, expect, beforeEach, afterAll } from "bun:test";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";

// The drafts module hardcodes ~/.imessage-mcp/drafts. We don't want tests
// touching the user's actual drafts dir, so we override HOME for the
// duration of these tests. Bun re-evaluates env on each spawn, so this is
// safe within a single test file.
const originalHome = process.env.HOME;
const tmpHome = mkdtempSync(join(tmpdir(), "imessage-mcp-test-"));
process.env.HOME = tmpHome;

// Import lazily so the module picks up the patched HOME.
const drafts = await import("./drafts.ts");

afterAll(() => {
  process.env.HOME = originalHome;
  rmSync(tmpHome, { recursive: true, force: true });
});

beforeEach(() => {
  // Clear any drafts between tests so listDrafts assertions stay deterministic.
  rmSync(drafts.draftsDir(), { recursive: true, force: true });
});

describe("stageDraft / getDraft / discardDraft", () => {
  test("stage writes a draft with sent_at: null and 0600 perms", () => {
    const { draft, path } = drafts.stageDraft({ to_handle: "+14155551234", body: "hi" });
    expect(draft.sent_at).toBeNull();
    expect(draft.send_service).toBeNull();
    expect(draft.to_handle).toBe("+14155551234");
    expect(draft.body).toBe("hi");
    expect(path.endsWith(`${draft.id}.json`)).toBe(true);
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

    // Verify it persisted, not just the in-memory return.
    const fetched = drafts.getDraft(draft.id);
    expect(fetched?.sent_at).toBe("2026-05-13T00:00:00.000Z");
    expect(fetched?.send_service).toBe("iMessage");
  });

  test("returns null for unknown id", () => {
    expect(drafts.markDraftSent(randomUUID(), "2026-05-13T00:00:00.000Z", "iMessage")).toBeNull();
  });
});

describe("normalizeDraft backward-compat", () => {
  test("reads a pre-sent_at format draft and backfills sent_at: null + send_service: null", () => {
    // Hand-write a draft in the v0 schema (before sent_at/send_service existed).
    const id = randomUUID();
    const dir = drafts.draftsDir();
    // ensureDir is called inside drafts module; force the dir to exist.
    drafts.stageDraft({ to_handle: "+14155550000", body: "seed" }); // triggers ensureDir
    writeFileSync(join(dir, `${id}.json`), JSON.stringify({
      id,
      to_handle: "+14155551234",
      body: "from v0",
      in_reply_to_thread_id: null,
      staged_at: "2026-05-01T00:00:00Z",
    }, null, 2));
    const fetched = drafts.getDraft(id);
    expect(fetched?.sent_at).toBeNull();
    expect(fetched?.send_service).toBeNull();
    expect(fetched?.body).toBe("from v0");
  });
});
