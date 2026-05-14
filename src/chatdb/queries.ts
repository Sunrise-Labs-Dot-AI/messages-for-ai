// All SQL against chat.db is parameterized and lives here. Keeping queries
// centralized makes it easy to audit for injection (none — parameters only)
// and for accidental unbounded scans.

import { openChatDb, appleDateToIsoUtc, isoUtcToAppleDateNs } from "./open.ts";
import { bestMessageBody, truncateBody, decodeAttributedBody } from "./decode.ts";
import { resolveHandle, resolveMany, findHandlesByContactName } from "./contacts.ts";

export interface ThreadSummary {
  thread_id: number;
  guid: string;
  display_name: string | null;
  is_group: boolean;
  participants: { handle: string; name: string | null }[];
  last_message_at: string | null;
  last_message_from: { handle: string | null; name: string | null; from_me: boolean } | null;
  last_message_preview: string | null;
}

export interface ThreadMessage {
  message_id: number;
  thread_id: number;
  sent_at: string | null;
  from_me: boolean;
  sender: { handle: string | null; name: string | null };
  body: string | null;
  is_read: boolean;
  has_attachments: boolean;
}

function escapeLike(s: string): string {
  return s.replace(/[\\%_]/g, (c) => `\\${c}`);
}

// Match a chat.db handle to the canonical form used by the AddressBook bulk
// loader. For phones the chat.db form is +14045610417 → "4045610417"; for
// emails, lowercase.
function canonChatHandle(id: string): string {
  if (id.includes("@")) return id.toLowerCase();
  const digits = id.replace(/[^\d]/g, "");
  return digits.length >= 10 ? digits.slice(-10) : digits;
}

// Cached map of canonical chat.db handle → its ROWID, populated on first use.
// chat.db's `handle` table is small (one row per (id, service) pair) so this
// is a one-time scan.
interface ChatHandleEntry { rowid: number; id: string; canon: string }
let chatHandlesCache: ChatHandleEntry[] | null = null;
function loadChatHandles(): ChatHandleEntry[] {
  if (chatHandlesCache) return chatHandlesCache;
  const db = openChatDb();
  const rows = db.query<{ ROWID: number; id: string }, []>(
    "SELECT ROWID, id FROM handle"
  ).all();
  chatHandlesCache = rows.map((r) => ({ rowid: r.ROWID, id: r.id, canon: canonChatHandle(r.id) }));
  return chatHandlesCache;
}

// Given a contact-name substring, return chat.db `handle.ROWID` values for
// any handle whose owner (per AddressBook) has a matching name. The caller
// uses these to widen a WHERE clause that would otherwise only match against
// the raw handle string.
function chatHandleRowIdsForContactName(filter: string): number[] {
  const targets = new Set(findHandlesByContactName(filter));
  if (targets.size === 0) return [];
  return loadChatHandles().filter((h) => targets.has(h.canon)).map((h) => h.rowid);
}

interface ListThreadRow {
  chat_id: number;
  guid: string;
  chat_display_name: string | null;
  style: number;
  last_msg_id: number;
  last_text: string | null;
  last_ab: Uint8Array | null;
  last_date: number | bigint | null;
  last_from_me: number;
  last_is_read: number;
  last_has_attach: number;
  last_handle_id: number | null;
  last_sender_handle: string | null;
}

function participantsForThreads(threadIds: readonly number[]): Map<number, string[]> {
  const out = new Map<number, string[]>();
  if (threadIds.length === 0) return out;
  const db = openChatDb();
  const placeholders = threadIds.map(() => "?").join(",");
  const rows = db.query<{ chat_id: number; handle: string }, number[]>(
    `SELECT chj.chat_id AS chat_id, h.id AS handle
     FROM chat_handle_join chj
     JOIN handle h ON h.ROWID = chj.handle_id
     WHERE chj.chat_id IN (${placeholders})`
  ).all(...threadIds);
  for (const r of rows) {
    const arr = out.get(r.chat_id) ?? [];
    arr.push(r.handle);
    out.set(r.chat_id, arr);
  }
  return out;
}

export interface ListThreadsArgs {
  limit: number;
  sinceIso?: string | undefined;
  beforeIso?: string | undefined;
  contactFilter?: string | undefined;
}

export interface ListThreadsResult {
  threads: ThreadSummary[];
  oldest_at: string | null;
  has_more: boolean;
}

export function listThreads(args: ListThreadsArgs): ListThreadsResult {
  const db = openChatDb();
  const { limit, sinceIso, beforeIso, contactFilter } = args;

  // Build the contact_filter widening list BEFORE the SQL: pre-resolve which
  // chat.db handle ROWIDs match the contact-name substring, so we can OR
  // them into the EXISTS clause as a fixed IN-list. This is what makes
  // contact_filter: "Catesby" work even though the raw handle is "+14045610417".
  const matchedHandleRowIds = contactFilter ? chatHandleRowIdsForContactName(contactFilter) : [];

  const params: (string | number | bigint)[] = [];
  let filterClause = "";

  if (sinceIso) {
    filterClause += " AND m.date >= ?";
    params.push(isoUtcToAppleDateNs(sinceIso));
  }
  if (beforeIso) {
    filterClause += " AND m.date < ?";
    params.push(isoUtcToAppleDateNs(beforeIso));
  }
  if (contactFilter) {
    const like = `%${escapeLike(contactFilter)}%`;
    const handleInClause = matchedHandleRowIds.length
      ? ` OR h2.ROWID IN (${matchedHandleRowIds.map(() => "?").join(",")})`
      : "";
    filterClause +=
      " AND (EXISTS (" +
      "SELECT 1 FROM chat_handle_join chj2 " +
      "JOIN handle h2 ON h2.ROWID = chj2.handle_id " +
      `WHERE chj2.chat_id = c.ROWID AND (LOWER(h2.id) LIKE LOWER(?) ESCAPE '\\'${handleInClause}))` +
      " OR LOWER(COALESCE(c.display_name, '')) LIKE LOWER(?) ESCAPE '\\')";
    params.push(like);
    for (const id of matchedHandleRowIds) params.push(id);
    params.push(like);
  }
  params.push(limit);

  // Recency CTE: MAX(message_id) per chat is much cheaper than MAX(date)
  // because it only touches chat_message_join (small) and not message (large).
  // chat_message_join.message_id is monotonic with insert order, which on
  // chat.db is effectively send order — a reliable proxy for "latest" in
  // all but the rare delete-and-restore case.
  const rows = db.query<ListThreadRow, (string | number | bigint)[]>(
    `WITH chat_recency AS (
       SELECT chat_id, MAX(message_id) AS last_msg_id
       FROM chat_message_join
       GROUP BY chat_id
     )
     SELECT c.ROWID AS chat_id,
            c.guid AS guid,
            c.display_name AS chat_display_name,
            c.style AS style,
            m.ROWID AS last_msg_id,
            m.text AS last_text,
            m.attributedBody AS last_ab,
            m.date AS last_date,
            m.is_from_me AS last_from_me,
            m.is_read AS last_is_read,
            m.cache_has_attachments AS last_has_attach,
            m.handle_id AS last_handle_id,
            h.id AS last_sender_handle
     FROM chat c
     JOIN chat_recency cr ON cr.chat_id = c.ROWID
     JOIN message m ON m.ROWID = cr.last_msg_id
     LEFT JOIN handle h ON h.ROWID = m.handle_id
     WHERE 1=1${filterClause}
     ORDER BY m.date DESC
     LIMIT ?`
  ).all(...params);

  const threadIds = rows.map((r) => r.chat_id);
  const partsByThread = participantsForThreads(threadIds);

  // Pre-resolve all participant + sender handles via the bulk in-memory map.
  const allHandles = new Set<string>();
  for (const arr of partsByThread.values()) for (const h of arr) allHandles.add(h);
  for (const r of rows) if (r.last_sender_handle) allHandles.add(r.last_sender_handle);
  const nameMap = resolveMany([...allHandles]);

  const threads: ThreadSummary[] = rows.map((r) => {
    const handles = partsByThread.get(r.chat_id) ?? [];
    return {
      thread_id: r.chat_id,
      guid: r.guid,
      display_name: r.chat_display_name,
      is_group: r.style === 43 || handles.length > 1,
      participants: handles.map((h) => ({ handle: h, name: nameMap.get(h) ?? null })),
      last_message_at: appleDateToIsoUtc(r.last_date),
      last_message_from:
        r.last_from_me === 1
          ? { handle: null, name: null, from_me: true }
          : {
              handle: r.last_sender_handle,
              name: r.last_sender_handle ? nameMap.get(r.last_sender_handle) ?? null : null,
              from_me: false,
            },
      last_message_preview: truncateBody(bestMessageBody(r.last_text, r.last_ab)),
    };
  });

  const oldest = threads.length > 0 ? threads[threads.length - 1]!.last_message_at : null;
  return { threads, oldest_at: oldest, has_more: threads.length === limit };
}

interface MessageRowLite {
  ROWID: number;
  text: string | null;
  attributedBody: Uint8Array | null;
  date: number | bigint | null;
  is_from_me: number;
  is_read: number;
  cache_has_attachments: number;
  handle_id: number | null;
  sender_handle: string | null;
  thread_id: number;
}

export interface GetThreadArgs {
  threadId: number;
  limit: number;
  beforeIso?: string | undefined;
}

export function getThreadMessages(args: GetThreadArgs): ThreadMessage[] {
  const db = openChatDb();
  const { threadId, limit, beforeIso } = args;
  const params: (string | number | bigint)[] = [threadId];
  let extra = "";
  if (beforeIso) {
    extra = " AND m.date < ?";
    params.push(isoUtcToAppleDateNs(beforeIso));
  }
  params.push(limit);
  const rows = db.query<MessageRowLite, (string | number | bigint)[]>(
    `SELECT m.ROWID AS ROWID,
            m.text AS text,
            m.attributedBody AS attributedBody,
            m.date AS date,
            m.is_from_me AS is_from_me,
            m.is_read AS is_read,
            m.cache_has_attachments AS cache_has_attachments,
            m.handle_id AS handle_id,
            h.id AS sender_handle,
            cmj.chat_id AS thread_id
     FROM chat_message_join cmj
     JOIN message m ON m.ROWID = cmj.message_id
     LEFT JOIN handle h ON h.ROWID = m.handle_id
     WHERE cmj.chat_id = ?${extra}
     ORDER BY m.date DESC
     LIMIT ?`
  ).all(...params);

  return rows.map((r) => ({
    message_id: r.ROWID,
    thread_id: r.thread_id,
    sent_at: appleDateToIsoUtc(r.date),
    from_me: r.is_from_me === 1,
    sender: {
      handle: r.is_from_me ? null : r.sender_handle,
      name: r.is_from_me ? null : r.sender_handle ? resolveHandle(r.sender_handle) : null,
    },
    body: truncateBody(bestMessageBody(r.text, r.attributedBody)),
    is_read: r.is_read === 1,
    has_attachments: r.cache_has_attachments === 1,
  }));
}

export interface SearchArgs {
  query: string;
  limit: number;
  sinceIso?: string | undefined;
  contactFilter?: string | undefined;
}

// Cap on how many candidate rows we'll pull from SQL before giving up.
// With required filters (since OR contact_filter) the candidate set should
// normally be in the hundreds, not thousands. The cap is a safety belt
// against pathological queries (e.g. very wide contact_filter + no since).
const SEARCH_SCAN_CAP = 5000;

export function searchMessages(args: SearchArgs): ThreadMessage[] {
  const db = openChatDb();
  const { query, limit, sinceIso, contactFilter } = args;

  // SQL filters (sargable): date + handle. Body text matching happens in JS
  // after we decode attributedBody, because attributedBody is a typedstream
  // BLOB that SQLite cannot LIKE-search reliably.
  const matchedHandleRowIds = contactFilter ? chatHandleRowIdsForContactName(contactFilter) : [];
  const params: (string | number | bigint)[] = [];
  let where = "WHERE 1=1";
  if (sinceIso) {
    where += " AND m.date >= ?";
    params.push(isoUtcToAppleDateNs(sinceIso));
  }
  if (contactFilter) {
    const like = `%${escapeLike(contactFilter)}%`;
    const handleInClause = matchedHandleRowIds.length
      ? ` OR h.ROWID IN (${matchedHandleRowIds.map(() => "?").join(",")})`
      : "";
    // Match if EITHER the message's sender handle matches OR any participant
    // in the message's thread does — covers "show me what Catesby said" and
    // "show me anything in Catesby's thread".
    where +=
      ` AND (LOWER(h.id) LIKE LOWER(?) ESCAPE '\\'${handleInClause} OR EXISTS (` +
      "SELECT 1 FROM chat_handle_join chj " +
      "JOIN handle h2 ON h2.ROWID = chj.handle_id " +
      `WHERE chj.chat_id = cmj.chat_id AND (LOWER(h2.id) LIKE LOWER(?) ESCAPE '\\'${handleInClause})))`;
    params.push(like);
    for (const id of matchedHandleRowIds) params.push(id);
    params.push(like);
    for (const id of matchedHandleRowIds) params.push(id);
  }
  params.push(SEARCH_SCAN_CAP);

  const rows = db.query<MessageRowLite, (string | number | bigint)[]>(
    `SELECT m.ROWID AS ROWID,
            m.text AS text,
            m.attributedBody AS attributedBody,
            m.date AS date,
            m.is_from_me AS is_from_me,
            m.is_read AS is_read,
            m.cache_has_attachments AS cache_has_attachments,
            m.handle_id AS handle_id,
            h.id AS sender_handle,
            cmj.chat_id AS thread_id
     FROM message m
     JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
     LEFT JOIN handle h ON h.ROWID = m.handle_id
     ${where}
     ORDER BY m.date DESC
     LIMIT ?`
  ).all(...params);

  const lowerQuery = query.toLowerCase();
  const matches: ThreadMessage[] = [];
  for (const r of rows) {
    // Cheap path first: if `text` exists and matches, we're done with this row.
    let body: string | null = r.text;
    if (!body || body.length === 0) {
      body = decodeAttributedBody(r.attributedBody);
    }
    if (!body) continue;
    if (!body.toLowerCase().includes(lowerQuery)) continue;
    matches.push({
      message_id: r.ROWID,
      thread_id: r.thread_id,
      sent_at: appleDateToIsoUtc(r.date),
      from_me: r.is_from_me === 1,
      sender: {
        handle: r.is_from_me ? null : r.sender_handle,
        name: r.is_from_me ? null : r.sender_handle ? resolveHandle(r.sender_handle) : null,
      },
      body: truncateBody(body),
      is_read: r.is_read === 1,
      has_attachments: r.cache_has_attachments === 1,
    });
    if (matches.length >= limit) break;
  }
  return matches;
}
