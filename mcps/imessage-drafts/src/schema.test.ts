import { describe, test, expect } from "bun:test";
import { z } from "zod";
import {
  ListThreadsShape,
  GetThreadShape,
  SearchShape,
  StageDraftShape,
  requireSinceOrContactFilter,
} from "./schema.ts";

const ListThreads = z.object(ListThreadsShape);
const GetThread = z.object(GetThreadShape);
const Search = z.object(SearchShape);
const StageDraft = z.object(StageDraftShape);

describe("ListThreadsShape", () => {
  test("accepts a valid since within 2 years", () => {
    const r = ListThreads.safeParse({ since: new Date().toISOString(), limit: 25 });
    expect(r.success).toBe(true);
  });

  test("rejects since older than 2 years", () => {
    const r = ListThreads.safeParse({ since: "2020-01-01T00:00:00Z" });
    expect(r.success).toBe(false);
    if (!r.success) {
      expect(r.error.issues.some((i) => i.message.includes("2 years"))).toBe(true);
    }
  });

  test("rejects contact_filter shorter than 2 chars", () => {
    const r = ListThreads.safeParse({ contact_filter: "x" });
    expect(r.success).toBe(false);
  });

  test("accepts before parameter", () => {
    const r = ListThreads.safeParse({ before: "2026-05-01T00:00:00Z", since: new Date().toISOString() });
    expect(r.success).toBe(true);
  });

  test("limit clamped to [1, 100]", () => {
    expect(ListThreads.safeParse({ limit: 0, since: new Date().toISOString() }).success).toBe(false);
    expect(ListThreads.safeParse({ limit: 101, since: new Date().toISOString() }).success).toBe(false);
    expect(ListThreads.safeParse({ limit: 100, since: new Date().toISOString() }).success).toBe(true);
  });
});

describe("requireSinceOrContactFilter", () => {
  test("rejects when both are missing", () => {
    expect(requireSinceOrContactFilter({})).not.toBeNull();
  });

  test("accepts when since is present", () => {
    expect(requireSinceOrContactFilter({ since: "2026-05-01T00:00:00Z" })).toBeNull();
  });

  test("accepts when contact_filter is present", () => {
    expect(requireSinceOrContactFilter({ contact_filter: "Catesby" })).toBeNull();
  });

  test("accepts when both are present", () => {
    expect(requireSinceOrContactFilter({ since: "2026-05-01T00:00:00Z", contact_filter: "Catesby" })).toBeNull();
  });
});

describe("SearchShape", () => {
  test("rejects query under 2 chars", () => {
    const r = Search.safeParse({ query: "a", since: new Date().toISOString() });
    expect(r.success).toBe(false);
  });

  test("accepts query of exactly 2 chars", () => {
    const r = Search.safeParse({ query: "ok", since: new Date().toISOString() });
    expect(r.success).toBe(true);
  });
});

describe("GetThreadShape", () => {
  test("requires positive thread_id", () => {
    expect(GetThread.safeParse({ thread_id: 0 }).success).toBe(false);
    expect(GetThread.safeParse({ thread_id: -1 }).success).toBe(false);
    expect(GetThread.safeParse({ thread_id: 1 }).success).toBe(true);
  });

  test("limit max 200", () => {
    expect(GetThread.safeParse({ thread_id: 1, limit: 201 }).success).toBe(false);
    expect(GetThread.safeParse({ thread_id: 1, limit: 200 }).success).toBe(true);
  });
});

describe("StageDraftShape", () => {
  test("accepts an email handle", () => {
    expect(StageDraft.safeParse({ to_handle: "friend@example.com", body: "hi" }).success).toBe(true);
  });

  test("accepts a phone handle", () => {
    expect(StageDraft.safeParse({ to_handle: "+14155551234", body: "hi" }).success).toBe(true);
  });

  test("rejects nonsense handles", () => {
    expect(StageDraft.safeParse({ to_handle: "not an address", body: "hi" }).success).toBe(false);
  });

  test("rejects empty body", () => {
    expect(StageDraft.safeParse({ to_handle: "+14155551234", body: "" }).success).toBe(false);
  });

  test("rejects body over 20 KB", () => {
    expect(StageDraft.safeParse({ to_handle: "+14155551234", body: "x".repeat(20_001) }).success).toBe(false);
  });
});
