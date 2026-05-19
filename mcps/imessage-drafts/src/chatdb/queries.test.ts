import { describe, test, expect, beforeEach } from "bun:test";
import { Database } from "bun:sqlite";
import { _setChatDbForTesting, isoUtcToAppleDateNs } from "./open.ts";
import { _setContactsForTesting, _resetContactsCache } from "./contacts.ts";
import {
  listThreads,
  getThreadMessages,
  searchMessages,
  _resetChatHandlesCacheForTesting,
} from "./queries.ts";

// ─── fixture builder ────────────────────────────────────────────────────────
// Minimal chat.db schema covering only the columns these queries touch.
// chat.db has many more columns in real life — recreating them all would
// add noise without changing test behavior.
function buildChatDb(): Database {
  const db = new Database(":memory:");
  db.exec(`
    CREATE TABLE chat (
      ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
      guid TEXT,
      display_name TEXT,
      style INTEGER
    );
    CREATE TABLE handle (
      ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
      id TEXT,
      service TEXT
    );
    CREATE TABLE message (
      ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
      text TEXT,
      attributedBody BLOB,
      date INTEGER,
      is_from_me INTEGER DEFAULT 0,
      is_read INTEGER DEFAULT 0,
      cache_has_attachments INTEGER DEFAULT 0,
      handle_id INTEGER
    );
    CREATE TABLE chat_message_join (
      chat_id INTEGER,
      message_id INTEGER
    );
    CREATE TABLE chat_handle_join (
      chat_id INTEGER,
      handle_id INTEGER
    );
  `);
  return db;
}

function nsAt(iso: string): bigint {
  return isoUtcToAppleDateNs(iso);
}

// Helpers for inserting rows. Each returns its ROWID for joining.
function insertChat(db: Database, opts: { guid: string; display_name?: string | null; style?: number }): number {
  db.run(`INSERT INTO chat (guid, display_name, style) VALUES (?, ?, ?)`, [
    opts.guid,
    opts.display_name ?? null,
    opts.style ?? 45,
  ]);
  return Number(db.query<{ id: number }, []>(`SELECT last_insert_rowid() AS id`).get()!.id);
}

function insertHandle(db: Database, opts: { id: string; service?: string }): number {
  db.run(`INSERT INTO handle (id, service) VALUES (?, ?)`, [opts.id, opts.service ?? "iMessage"]);
  return Number(db.query<{ id: number }, []>(`SELECT last_insert_rowid() AS id`).get()!.id);
}

function linkChatHandle(db: Database, chat_id: number, handle_id: number): void {
  db.run(`INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (?, ?)`, [chat_id, handle_id]);
}

function insertMessage(
  db: Database,
  opts: {
    chat_id: number;
    text: string | null;
    attributedBody?: Uint8Array | null;
    date_iso: string;
    is_from_me?: boolean;
    handle_id?: number | null;
  }
): number {
  db.run(
    `INSERT INTO message (text, attributedBody, date, is_from_me, handle_id) VALUES (?, ?, ?, ?, ?)`,
    [
      opts.text,
      opts.attributedBody ?? null,
      nsAt(opts.date_iso),
      opts.is_from_me ? 1 : 0,
      opts.handle_id ?? null,
    ]
  );
  const msg_id = Number(db.query<{ id: number }, []>(`SELECT last_insert_rowid() AS id`).get()!.id);
  db.run(`INSERT INTO chat_message_join (chat_id, message_id) VALUES (?, ?)`, [opts.chat_id, msg_id]);
  return msg_id;
}

// Build a small typedstream attributedBody blob carrying `text` — same
// shape as decode.test.ts's helper, kept local so this fixture file is
// self-contained.
function buildAttributedBody(text: string): Buffer {
  const utf8 = Buffer.from(text, "utf8");
  if (utf8.length >= 0x80) throw new Error("fixture only handles short strings");
  return Buffer.concat([
    Buffer.from("streamtyped\x00", "binary"),
    Buffer.from("NSString", "utf8"),
    Buffer.from([0x86, 0x84, 0x40, 0x40]),
    Buffer.from([0x01, 0x2b]),
    Buffer.from([utf8.length]),
    utf8,
  ]);
}

// ─── tests ──────────────────────────────────────────────────────────────────

let db: Database;

beforeEach(() => {
  db = buildChatDb();
  _setChatDbForTesting(db);
  _resetChatHandlesCacheForTesting();
  _resetContactsCache();
});

describe("listThreads", () => {
  test("returns threads newest-first with last_message_at / preview", () => {
    const h1 = insertHandle(db, { id: "+14155551111" });
    const h2 = insertHandle(db, { id: "+14155552222" });
    const c1 = insertChat(db, { guid: "c1" });
    const c2 = insertChat(db, { guid: "c2" });
    linkChatHandle(db, c1, h1);
    linkChatHandle(db, c2, h2);
    insertMessage(db, { chat_id: c1, text: "hello from c1", date_iso: "2026-05-10T12:00:00Z", handle_id: h1 });
    insertMessage(db, { chat_id: c2, text: "hello from c2", date_iso: "2026-05-12T12:00:00Z", handle_id: h2 });

    const r = listThreads({ limit: 10, sinceIso: "2026-05-01T00:00:00Z" });
    expect(r.threads.length).toBe(2);
    expect(r.threads[0]!.thread_id).toBe(c2);
    expect(r.threads[0]!.last_message_preview).toBe("hello from c2");
    expect(r.threads[1]!.thread_id).toBe(c1);
    expect(r.oldest_at).toBe(r.threads[1]!.last_message_at);
    expect(r.has_more).toBe(false);
  });

  test("respects `before` cursor strictly less than (no boundary duplication)", () => {
    const h = insertHandle(db, { id: "+14155551111" });
    const c1 = insertChat(db, { guid: "c1" });
    const c2 = insertChat(db, { guid: "c2" });
    const c3 = insertChat(db, { guid: "c3" });
    linkChatHandle(db, c1, h);
    linkChatHandle(db, c2, h);
    linkChatHandle(db, c3, h);
    insertMessage(db, { chat_id: c1, text: "old", date_iso: "2026-05-10T12:00:00Z", handle_id: h });
    insertMessage(db, { chat_id: c2, text: "mid", date_iso: "2026-05-11T12:00:00Z", handle_id: h });
    insertMessage(db, { chat_id: c3, text: "new", date_iso: "2026-05-12T12:00:00Z", handle_id: h });

    // Page 1: limit 2, newest first.
    const page1 = listThreads({ limit: 2, sinceIso: "2026-05-01T00:00:00Z" });
    expect(page1.threads.map((t) => t.thread_id)).toEqual([c3, c2]);
    expect(page1.has_more).toBe(true);
    expect(page1.oldest_at).toBe("2026-05-11T12:00:00.000Z");

    // Page 2 using oldest_at as the `before` cursor. c2 must NOT reappear.
    const page2 = listThreads({ limit: 2, sinceIso: "2026-05-01T00:00:00Z", beforeIso: page1.oldest_at! });
    expect(page2.threads.map((t) => t.thread_id)).toEqual([c1]);
    expect(page2.has_more).toBe(false);
  });

  test("contact_filter matches resolved Contact name even when raw handle differs (the Catesby fix)", () => {
    const h_catesby = insertHandle(db, { id: "+14045610417" });
    const h_other = insertHandle(db, { id: "+14155551234" });
    const c_catesby = insertChat(db, { guid: "c_catesby" });
    const c_other = insertChat(db, { guid: "c_other" });
    linkChatHandle(db, c_catesby, h_catesby);
    linkChatHandle(db, c_other, h_other);
    insertMessage(db, { chat_id: c_catesby, text: "hey", date_iso: "2026-05-12T12:00:00Z", handle_id: h_catesby });
    insertMessage(db, { chat_id: c_other, text: "yo", date_iso: "2026-05-12T11:00:00Z", handle_id: h_other });

    // Inject contacts so the name->handles index has "catesby perrin" -> ["4045610417"].
    _setContactsForTesting(
      new Map([["4045610417", "Catesby Perrin"]]),
      [{ lower_name: "catesby perrin", handles: ["4045610417"] }]
    );

    const r = listThreads({ limit: 10, contactFilter: "Catesby" });
    expect(r.threads.length).toBe(1);
    expect(r.threads[0]!.thread_id).toBe(c_catesby);
    expect(r.threads[0]!.participants[0]!.name).toBe("Catesby Perrin");
  });

  test("contact_filter still matches raw handle substring when no Contact match", () => {
    const h = insertHandle(db, { id: "+14155551234" });
    const c = insertChat(db, { guid: "c" });
    linkChatHandle(db, c, h);
    insertMessage(db, { chat_id: c, text: "hi", date_iso: "2026-05-12T12:00:00Z", handle_id: h });

    _setContactsForTesting(new Map(), []); // no contacts known
    const r = listThreads({ limit: 10, contactFilter: "415555" });
    expect(r.threads.length).toBe(1);
    expect(r.threads[0]!.thread_id).toBe(c);
  });
});

describe("getThreadMessages", () => {
  test("returns messages newest-first; decodes attributedBody when text is null", () => {
    const h = insertHandle(db, { id: "+14155551111" });
    const c = insertChat(db, { guid: "c" });
    linkChatHandle(db, c, h);
    insertMessage(db, { chat_id: c, text: "first", date_iso: "2026-05-10T12:00:00Z", handle_id: h });
    insertMessage(db, {
      chat_id: c,
      text: null,
      attributedBody: buildAttributedBody("from blob"),
      date_iso: "2026-05-11T12:00:00Z",
      handle_id: h,
    });

    const rows = getThreadMessages({ threadId: c, limit: 10 });
    expect(rows.length).toBe(2);
    expect(rows[0]!.body).toBe("from blob");
    expect(rows[1]!.body).toBe("first");
  });
});

describe("searchMessages — attributedBody decode (Fix 3)", () => {
  test("matches inside attributedBody when text column is null", () => {
    const h = insertHandle(db, { id: "+14155551111" });
    const c = insertChat(db, { guid: "c" });
    linkChatHandle(db, c, h);
    insertMessage(db, {
      chat_id: c,
      text: null,
      attributedBody: buildAttributedBody("thanks my dude"),
      date_iso: "2026-05-12T12:00:00Z",
      handle_id: h,
    });

    const hits = searchMessages({ query: "thanks", limit: 10, sinceIso: "2026-05-01T00:00:00Z" });
    expect(hits.length).toBe(1);
    expect(hits[0]!.body).toBe("thanks my dude");
  });

  test("does not match when neither text nor attributedBody contains the query", () => {
    const h = insertHandle(db, { id: "+14155551111" });
    const c = insertChat(db, { guid: "c" });
    linkChatHandle(db, c, h);
    insertMessage(db, {
      chat_id: c,
      text: "no thanks here",
      date_iso: "2026-05-12T12:00:00Z",
      handle_id: h,
    });

    const hits = searchMessages({ query: "zzznomatch", limit: 10, sinceIso: "2026-05-01T00:00:00Z" });
    expect(hits.length).toBe(0);
  });

  test("contact_filter on search widens through resolved names", () => {
    const h_c = insertHandle(db, { id: "+14045610417" });
    const h_o = insertHandle(db, { id: "+14155551234" });
    const chat_c = insertChat(db, { guid: "c_c" });
    const chat_o = insertChat(db, { guid: "c_o" });
    linkChatHandle(db, chat_c, h_c);
    linkChatHandle(db, chat_o, h_o);
    insertMessage(db, { chat_id: chat_c, text: "thanks", date_iso: "2026-05-12T12:00:00Z", handle_id: h_c });
    insertMessage(db, { chat_id: chat_o, text: "thanks", date_iso: "2026-05-12T12:00:00Z", handle_id: h_o });

    _setContactsForTesting(
      new Map([["4045610417", "Catesby Perrin"]]),
      [{ lower_name: "catesby perrin", handles: ["4045610417"] }]
    );

    const hits = searchMessages({ query: "thanks", limit: 10, contactFilter: "Catesby" });
    expect(hits.length).toBe(1);
    expect(hits[0]!.thread_id).toBe(chat_c);
  });
});
