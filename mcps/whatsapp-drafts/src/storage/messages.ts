// Persistent message cache. Baileys emits messages.upsert / messaging-
// history.set events; this module is the write target. All read tools
// (list_whatsapp_threads, get_whatsapp_thread, search_whatsapps) read
// from here — never directly from Baileys in-memory state. Decouples
// read latency from connection state and survives reconnects.
//
// Plaintext at rest (symmetric with how Apple stores iMessage chat.db).
// Relies on FileVault + 0600 perms. The CREDENTIAL in session.db is
// AES-GCM wrapped; messages are not. See §Security architecture in the
// planning doc for the asymmetry rationale.

import { Database } from "bun:sqlite";
import { chmodSync, existsSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";

import { PATHS } from "../paths.ts";
import { DEFAULT_BODY_CAP_BYTES, sanitizeIncomingBody, truncateToBytes } from "../tools/_untrusted.ts";

const SCHEMA_SQL = `
CREATE TABLE IF NOT EXISTS messages (
  message_id      TEXT NOT NULL,
  thread_jid      TEXT NOT NULL,
  sender_jid      TEXT NOT NULL,
  from_me         INTEGER NOT NULL,
  ts              INTEGER NOT NULL,
  body            TEXT,
  body_full       BLOB,
  body_sha256     TEXT,
  message_type    TEXT NOT NULL,
  attachment_meta TEXT,
  reply_to_id     TEXT,
  inserted_at     INTEGER NOT NULL,
  source          TEXT NOT NULL,
  PRIMARY KEY (thread_jid, message_id)
);
CREATE INDEX IF NOT EXISTS idx_messages_ts ON messages(ts DESC);
CREATE INDEX IF NOT EXISTS idx_messages_thread_ts ON messages(thread_jid, ts DESC);

CREATE TABLE IF NOT EXISTS threads (
  thread_jid       TEXT PRIMARY KEY,
  display_name     TEXT,
  is_group         INTEGER NOT NULL,
  last_message_ts  INTEGER NOT NULL,
  last_seen_at     INTEGER
);

CREATE TABLE IF NOT EXISTS contacts (
  jid           TEXT PRIMARY KEY,
  display_name  TEXT,
  push_name     TEXT,
  is_business   INTEGER NOT NULL DEFAULT 0
);
`;

export type MessageType = "text" | "image" | "voice" | "video" | "document" | "system";
export type MessageSource = "live" | "history-sync";

export interface IngestMessage {
  message_id: string;
  thread_jid: string;
  sender_jid: string;
  from_me: boolean;
  ts: number;            // unix ms
  body: string | null;   // raw body; sanitized + truncated at write time
  message_type: MessageType;
  attachment_meta?: { caption?: string; filename?: string; mime?: string } | null;
  reply_to_id?: string | null;
  source: MessageSource;
}

export interface UpsertThread {
  thread_jid: string;
  display_name?: string | null;
  is_group: boolean;
  last_message_ts: number;
}

export interface UpsertContact {
  jid: string;
  display_name?: string | null;
  push_name?: string | null;
  is_business?: boolean;
}

export interface ThreadRow {
  thread_jid: string;
  display_name: string | null;
  is_group: boolean;
  last_message_ts: number;
  last_seen_at: number | null;
}

export interface MessageRow {
  message_id: string;
  thread_jid: string;
  sender_jid: string;
  /** Best-effort human-readable sender name resolved at read time via
   *  the contacts table. Null for unknown senders (typically @lid
   *  privacy-format JIDs that don't have a contacts row yet). For
   *  `from_me=true` messages this is null — callers render those as
   *  "Me" / "You" themselves. */
  sender_name: string | null;
  from_me: boolean;
  ts: number;
  body: string | null;
  body_sha256: string | null;
  message_type: MessageType;
  attachment_meta: { caption?: string; filename?: string; mime?: string } | null;
  reply_to_id: string | null;
}

let _db: Database | null = null;

/** Open (or return cached) handle to messages.db. Exported so tests can
 *  reset table contents between cases without re-opening the file. */
export function getMessagesDb(): Database {
  if (_db != null) return _db;
  const path = PATHS.messagesDb;
  if (!existsSync(dirname(path))) {
    mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  }
  const db = new Database(path, { create: true });
  db.exec("PRAGMA journal_mode = WAL");
  db.exec("PRAGMA synchronous = NORMAL");
  db.exec(SCHEMA_SQL);
  // 0600 on the main DB. WAL/SHM sidecars are created lazily by SQLite;
  // we re-chmod them whenever we know they exist.
  try { chmodSync(path, 0o600); } catch { /* not yet on disk in some edge cases */ }
  for (const suffix of ["-wal", "-shm"] as const) {
    try { chmodSync(path + suffix, 0o600); } catch { /* not created yet */ }
  }
  _db = db;

  // One-time backfill: heal any threads whose last_message_ts is 0 but
  // for which we actually have messages. This recovers from a bug where
  // an earlier daemon version stored last_message_ts=0 because it didn't
  // unpack Baileys' protobuf-Long conversationTimestamp. Idempotent —
  // a fresh install has 0 rows in both tables and this no-ops.
  db.exec(`
    UPDATE threads SET last_message_ts = COALESCE((
      SELECT MAX(ts) FROM messages WHERE messages.thread_jid = threads.thread_jid
    ), 0)
    WHERE last_message_ts = 0
      AND EXISTS (SELECT 1 FROM messages WHERE messages.thread_jid = threads.thread_jid)
  `);

  return db;
}

/** Hex SHA-256 of a string. */
function sha256(input: string): string {
  return new Bun.CryptoHasher("sha256").update(input).digest("hex");
}

/**
 * Insert a message. Idempotent on (thread_jid, message_id).
 *
 * - body is sanitized (tag-escape) and truncated to DEFAULT_BODY_CAP_BYTES
 *   before insert. body_full retains the full sanitized form for explicit
 *   get_whatsapp_message_full retrieval.
 * - body_sha256 hashes the FULL sanitized body (not the truncated one) so
 *   audit comparisons remain stable.
 * - Also UPSERTs threads.last_message_ts to MAX(existing, new). This is
 *   the authoritative source for thread recency — never trust Baileys'
 *   conversationTimestamp because it's emitted as a protobuf Long that
 *   we'd have to unpack correctly in every event handler.
 */
export function insertMessage(m: IngestMessage): { inserted: boolean } {
  const db = getMessagesDb();

  let bodyTrunc: string | null = null;
  let bodyFull: Buffer | null = null;
  let bodySha: string | null = null;
  if (m.body != null) {
    const sanitized = sanitizeIncomingBody(m.body);
    const { body: truncated, truncated: didTruncate } = truncateToBytes(sanitized);
    bodyTrunc = truncated;
    bodyFull = didTruncate ? Buffer.from(sanitized, "utf8") : null;
    bodySha = sha256(sanitized);
  }

  const stmt = db.prepare(`
    INSERT OR IGNORE INTO messages
      (message_id, thread_jid, sender_jid, from_me, ts, body, body_full,
       body_sha256, message_type, attachment_meta, reply_to_id, inserted_at, source)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `);
  const result = stmt.run(
    m.message_id,
    m.thread_jid,
    m.sender_jid,
    m.from_me ? 1 : 0,
    m.ts,
    bodyTrunc,
    bodyFull,
    bodySha,
    m.message_type,
    m.attachment_meta ? JSON.stringify(m.attachment_meta) : null,
    m.reply_to_id ?? null,
    Date.now(),
    m.source,
  );

  // Also bump threads.last_message_ts so list_whatsapp_threads can filter
  // by recency. UPSERT semantics: create the thread row if it didn't
  // already exist (which can happen if messaging-history.set delivered
  // messages before the chat metadata), otherwise raise last_message_ts.
  db.prepare(`
    INSERT INTO threads (thread_jid, display_name, is_group, last_message_ts)
    VALUES (?, NULL, ?, ?)
    ON CONFLICT(thread_jid) DO UPDATE SET
      last_message_ts = MAX(threads.last_message_ts, excluded.last_message_ts)
  `).run(m.thread_jid, m.thread_jid.endsWith("@g.us") ? 1 : 0, m.ts);

  return { inserted: result.changes > 0 };
}

export function upsertThread(t: UpsertThread): void {
  const db = getMessagesDb();
  db.prepare(`
    INSERT INTO threads (thread_jid, display_name, is_group, last_message_ts)
    VALUES (?, ?, ?, ?)
    ON CONFLICT(thread_jid) DO UPDATE SET
      display_name = COALESCE(excluded.display_name, threads.display_name),
      is_group = excluded.is_group,
      last_message_ts = MAX(threads.last_message_ts, excluded.last_message_ts)
  `).run(
    t.thread_jid,
    t.display_name ?? null,
    t.is_group ? 1 : 0,
    t.last_message_ts,
  );
}

export function upsertContact(c: UpsertContact): void {
  const db = getMessagesDb();
  db.prepare(`
    INSERT INTO contacts (jid, display_name, push_name, is_business)
    VALUES (?, ?, ?, ?)
    ON CONFLICT(jid) DO UPDATE SET
      display_name = COALESCE(excluded.display_name, contacts.display_name),
      push_name    = COALESCE(excluded.push_name, contacts.push_name),
      is_business  = excluded.is_business
  `).run(
    c.jid,
    c.display_name ?? null,
    c.push_name ?? null,
    c.is_business ? 1 : 0,
  );
}

/**
 * Best-effort human-readable name for a JID. Tries the contacts table
 * (display_name → push_name → null), then the threads table's
 * display_name (Baileys names groups even when individual contacts are
 * un-named). Returns null if nothing matches — caller decides on a
 * presentation fallback (typically `formatJidAsPhone`).
 */
export function getContactDisplayName(jid: string): string | null {
  const db = getMessagesDb();
  const contact = db
    .prepare("SELECT display_name, push_name FROM contacts WHERE jid = ?")
    .get(jid) as { display_name: string | null; push_name: string | null } | undefined;
  if (contact != null) {
    const name = contact.display_name ?? contact.push_name;
    if (name != null && name.trim().length > 0) return name;
  }
  const thread = db
    .prepare("SELECT display_name FROM threads WHERE thread_jid = ?")
    .get(jid) as { display_name: string | null } | undefined;
  if (thread?.display_name != null && thread.display_name.trim().length > 0) {
    return thread.display_name;
  }
  return null;
}

/**
 * Pretty-format a WhatsApp user JID as a phone number when no contact
 * name is available. "12158055729@s.whatsapp.net" → "+1 (215) 805-5729".
 * Group JIDs and unparseable inputs round-trip unchanged.
 */
export function formatJidAsPhone(jid: string): string {
  const at = jid.indexOf("@");
  if (at < 0) return jid;
  const suffix = jid.slice(at);
  if (suffix === "@g.us") return jid;  // groups: caller should prefer thread name
  const num = jid.slice(0, at).replace(/[^0-9]/g, "");
  if (num.length === 0) return jid;
  // US/CA numbers (11 digits starting with 1) get the (NNN) NNN-NNNN
  // pretty form; everything else just gets the leading "+".
  if (num.length === 11 && num.startsWith("1")) {
    return `+1 (${num.slice(1, 4)}) ${num.slice(4, 7)}-${num.slice(7, 11)}`;
  }
  return `+${num}`;
}

/**
 * List threads with a recent message in [since, now]. Optionally filter
 * threads whose display_name OR jid contains contact_filter (substring).
 */
export function listThreads(opts: {
  since?: number;
  contact_filter?: string;
  limit?: number;
}): ThreadRow[] {
  const db = getMessagesDb();
  const where: string[] = [];
  const params: (string | number)[] = [];
  if (opts.since != null) {
    where.push("threads.last_message_ts >= ?");
    params.push(opts.since);
  }
  if (opts.contact_filter != null && opts.contact_filter.length > 0) {
    where.push("(threads.display_name LIKE ? OR threads.thread_jid LIKE ?)");
    const like = `%${opts.contact_filter}%`;
    params.push(like, like);
  }
  // For groups: threads.display_name is set by Baileys's group-meta sync.
  // For individuals: threads.display_name is null (each side knows the
  // other by phone, not by a thread label), so fall back to the contacts
  // table — that's where Baileys writes the Mac Contacts display_name
  // and the WhatsApp profile push_name on contacts.upsert. Without this
  // join, every individual chat surfaces to Claude as a raw JID and
  // contact_filter substring-matches only group names. With the join,
  // ~70% of individual chats resolve (the rest are @lid entries — a
  // known follow-up for Baileys's privacy-format mapping).
  if (opts.contact_filter != null && opts.contact_filter.length > 0) {
    // Replace the basic display_name LIKE clause above with one that
    // also searches the joined contact name.
    where.pop();
    const like = `%${opts.contact_filter}%`;
    params.pop(); params.pop();
    where.push("(threads.display_name LIKE ? OR threads.thread_jid LIKE ? OR contacts.display_name LIKE ? OR contacts.push_name LIKE ?)");
    params.push(like, like, like, like);
  }
  const whereSql = where.length > 0 ? `WHERE ${where.join(" AND ")}` : "";
  const limit = opts.limit ?? 100;
  const rows = db.prepare(`
    SELECT
      threads.thread_jid,
      COALESCE(threads.display_name, contacts.display_name, contacts.push_name) AS display_name,
      threads.is_group,
      threads.last_message_ts,
      threads.last_seen_at
    FROM threads
    LEFT JOIN contacts ON contacts.jid = threads.thread_jid
    ${whereSql}
    ORDER BY threads.last_message_ts DESC
    LIMIT ?
  `).all(...params, limit) as Array<{
    thread_jid: string;
    display_name: string | null;
    is_group: number;
    last_message_ts: number;
    last_seen_at: number | null;
  }>;
  return rows.map((r) => ({
    thread_jid: r.thread_jid,
    display_name: r.display_name,
    is_group: r.is_group === 1,
    last_message_ts: r.last_message_ts,
    last_seen_at: r.last_seen_at,
  }));
}

export function getThreadMessages(opts: {
  thread_jid: string;
  before_ts?: number;
  limit?: number;
}): MessageRow[] {
  const db = getMessagesDb();
  const limit = opts.limit ?? 50;
  const before = opts.before_ts ?? Number.MAX_SAFE_INTEGER;
  // LEFT JOIN to contacts so the MCP-side tools (and the menubar's
  // context bubbles) see real names instead of raw JIDs. Inbound
  // messages whose sender_jid doesn't have a matching contacts row
  // (mainly @lid privacy-format senders Baileys hasn't mapped yet)
  // get sender_name = null and the caller falls back to phone-format.
  const rows = db.prepare(`
    SELECT m.message_id, m.thread_jid, m.sender_jid, m.from_me, m.ts,
           m.body, m.body_sha256, m.message_type, m.attachment_meta,
           m.reply_to_id,
           COALESCE(c.display_name, c.push_name) AS sender_name
    FROM messages m
    LEFT JOIN contacts c ON c.jid = m.sender_jid
    WHERE m.thread_jid = ? AND m.ts < ?
    ORDER BY m.ts DESC
    LIMIT ?
  `).all(opts.thread_jid, before, limit) as Array<{
    message_id: string;
    thread_jid: string;
    sender_jid: string;
    sender_name: string | null;
    from_me: number;
    ts: number;
    body: string | null;
    body_sha256: string | null;
    message_type: MessageType;
    attachment_meta: string | null;
    reply_to_id: string | null;
  }>;
  return rows.map((r) => ({
    message_id: r.message_id,
    thread_jid: r.thread_jid,
    sender_jid: r.sender_jid,
    sender_name: r.from_me === 1 ? null : r.sender_name,
    from_me: r.from_me === 1,
    ts: r.ts,
    body: r.body,
    body_sha256: r.body_sha256,
    message_type: r.message_type,
    attachment_meta: r.attachment_meta ? JSON.parse(r.attachment_meta) : null,
    reply_to_id: r.reply_to_id,
  }));
}

export function getMessageFull(thread_jid: string, message_id: string): string | null {
  const db = getMessagesDb();
  const row = db.prepare(`
    SELECT body, body_full FROM messages
    WHERE thread_jid = ? AND message_id = ?
  `).get(thread_jid, message_id) as { body: string | null; body_full: Buffer | null } | null;
  if (row == null) return null;
  if (row.body_full != null) return Buffer.from(row.body_full).toString("utf8");
  return row.body;
}

export function searchMessages(opts: {
  query: string;
  since?: number;
  contact_filter?: string;
  limit?: number;
}): MessageRow[] {
  const db = getMessagesDb();
  const where: string[] = ["m.body LIKE ? COLLATE NOCASE"];
  const params: (string | number)[] = [`%${opts.query}%`];
  if (opts.since != null) {
    where.push("m.ts >= ?");
    params.push(opts.since);
  }
  if (opts.contact_filter != null && opts.contact_filter.length > 0) {
    // Match thread name (group), thread JID, or the resolved sender's
    // contact name — so "search for messages from Paul" surfaces hits
    // even when the thread itself isn't named after Paul.
    where.push("(t.display_name LIKE ? OR m.thread_jid LIKE ? OR ct.display_name LIKE ? OR ct.push_name LIKE ?)");
    const like = `%${opts.contact_filter}%`;
    params.push(like, like, like, like);
  }
  const limit = opts.limit ?? 50;
  const rows = db.prepare(`
    SELECT m.message_id, m.thread_jid, m.sender_jid, m.from_me, m.ts, m.body,
           m.body_sha256, m.message_type, m.attachment_meta, m.reply_to_id,
           COALESCE(cs.display_name, cs.push_name) AS sender_name
    FROM messages m
    LEFT JOIN threads t ON t.thread_jid = m.thread_jid
    LEFT JOIN contacts ct ON ct.jid = m.thread_jid
    LEFT JOIN contacts cs ON cs.jid = m.sender_jid
    WHERE ${where.join(" AND ")}
    ORDER BY m.ts DESC
    LIMIT ?
  `).all(...params, limit) as Array<{
    message_id: string;
    thread_jid: string;
    sender_jid: string;
    sender_name: string | null;
    from_me: number;
    ts: number;
    body: string | null;
    body_sha256: string | null;
    message_type: MessageType;
    attachment_meta: string | null;
    reply_to_id: string | null;
  }>;
  return rows.map((r) => ({
    message_id: r.message_id,
    thread_jid: r.thread_jid,
    sender_jid: r.sender_jid,
    sender_name: r.from_me === 1 ? null : r.sender_name,
    from_me: r.from_me === 1,
    ts: r.ts,
    body: r.body,
    body_sha256: r.body_sha256,
    message_type: r.message_type,
    attachment_meta: r.attachment_meta ? JSON.parse(r.attachment_meta) : null,
    reply_to_id: r.reply_to_id,
  }));
}

/** Delete messages older than `retentionMs` from now. Returns rows deleted. */
export function sweepOldMessages(retentionMs: number): number {
  const db = getMessagesDb();
  const cutoff = Date.now() - retentionMs;
  const result = db.prepare("DELETE FROM messages WHERE ts < ?").run(cutoff);
  return Number(result.changes);
}

/** Test seam — close and re-open on next call. */
export function _resetForTesting(): void {
  if (_db != null) {
    _db.close();
    _db = null;
  }
}

// Re-export so callers don't need to import from _untrusted.ts.
export { DEFAULT_BODY_CAP_BYTES };
