// Resolve a chat.db handle.id (phone like "+14155551234" or email) to a human
// display name from the macOS Contacts database. We avoid AppleScript (slow,
// requires automation entitlement) and read the local AddressBook SQLite
// directly. It's the same TCC-protected zone as chat.db, so any process that
// has Full Disk Access for chat.db also has it for AddressBook.
//
// All contacts are bulk-loaded into memory on first use — for a typical Mac
// AddressBook (~500–5000 records) this is <100ms and avoids the leading-%
// LIKE on `ZABCDPHONENUMBER` that made per-handle resolution slow at scale.

import { Database } from "bun:sqlite";
import { homedir } from "node:os";
import { readdirSync, existsSync } from "node:fs";
import { join } from "node:path";

let loaded = false;
let handleToName = new Map<string, string>(); // canonicalized handle -> name
let nameIndex: { lower_name: string; handles: string[] }[] = []; // for substring search

function findAddressBookDb(): string | null {
  // Prefer a source-specific DB (Sources/{uuid}/AddressBook-v22.abcddb) since
  // it's the canonical location used by multi-account setups. Fall through to
  // the top-level path when the Sources scan is unavailable or empty.
  //
  // IMPORTANT: the Sources-scan try/catch is intentionally separate from the
  // outer guard. readdirSync(sourcesRoot) raises EPERM when TCC hasn't yet
  // granted access to that specific sub-path (even when FDA is granted for the
  // top-level AddressBook dir). Catching the inner error lets us fall through
  // to the top-level path rather than short-circuiting to null.
  try {
    const sourcesRoot = join(homedir(), "Library", "Application Support", "AddressBook", "Sources");
    if (existsSync(sourcesRoot)) {
      try {
        for (const source of readdirSync(sourcesRoot)) {
          const candidate = join(sourcesRoot, source, "AddressBook-v22.abcddb");
          if (existsSync(candidate)) return candidate;
        }
      } catch {
        // Sources scan failed (EPERM or similar) — fall through to top-level path.
      }
    }
    const top = join(homedir(), "Library", "Application Support", "AddressBook", "AddressBook-v22.abcddb");
    return existsSync(top) ? top : null;
  } catch {
    return null;
  }
}

// Canonicalize a phone or email for handle-lookup. For phones: digits only,
// take last 10 ("US-style" suffix matching that ignores +1 vs no-country).
// For emails: lowercase. The chat.db handle.id for a phone uses E.164
// (+14155551234) while AddressBook stores any user-entered formatting.
// Matching by the last 10 digits is the common workaround.
function canonHandle(s: string): string {
  if (s.includes("@")) return s.toLowerCase();
  const digits = s.replace(/[^\d]/g, "");
  return digits.length >= 10 ? digits.slice(-10) : digits;
}

interface RecordRow {
  Z_PK: number;
  ZFIRSTNAME: string | null;
  ZLASTNAME: string | null;
  ZORGANIZATION: string | null;
}

interface EmailRow { ZOWNER: number; ZADDRESS: string | null }
interface PhoneRow { ZOWNER: number; ZFULLNUMBER: string | null }

function nameFromRow(row: RecordRow | undefined): string | null {
  if (!row) return null;
  const first = (row.ZFIRSTNAME ?? "").trim();
  const last = (row.ZLASTNAME ?? "").trim();
  const org = (row.ZORGANIZATION ?? "").trim();
  const name = [first, last].filter(Boolean).join(" ").trim();
  return name || org || null;
}

function load(): void {
  if (loaded) return;
  loaded = true; // mark loaded even on failure to avoid retry storms
  const path = findAddressBookDb();
  if (!path) return;

  let db: Database;
  try {
    db = new Database(path, { readonly: true });
    db.exec("PRAGMA query_only = ON;");
  } catch {
    return; // FDA likely denied; keep empty maps as the graceful fallback
  }

  let records: RecordRow[];
  let emails: EmailRow[];
  let phones: PhoneRow[];
  try {
    records = db.query<RecordRow, []>("SELECT Z_PK, ZFIRSTNAME, ZLASTNAME, ZORGANIZATION FROM ZABCDRECORD").all();
    emails = db.query<EmailRow, []>("SELECT ZOWNER, ZADDRESS FROM ZABCDEMAILADDRESS").all();
    phones = db.query<PhoneRow, []>("SELECT ZOWNER, ZFULLNUMBER FROM ZABCDPHONENUMBER").all();
  } catch {
    return;
  } finally {
    try { db.close(); } catch { /* ignore */ }
  }

  const recordsByPk = new Map<number, RecordRow>();
  for (const r of records) recordsByPk.set(r.Z_PK, r);

  // Group handles per record so we can build the name->handles index in one pass.
  const handlesPerRecord = new Map<number, string[]>();
  function pushHandle(owner: number, handle: string) {
    if (!handle) return;
    const arr = handlesPerRecord.get(owner) ?? [];
    arr.push(handle);
    handlesPerRecord.set(owner, arr);
  }

  for (const e of emails) {
    if (!e.ZADDRESS || e.ZOWNER == null) continue;
    const name = nameFromRow(recordsByPk.get(e.ZOWNER));
    if (name) handleToName.set(canonHandle(e.ZADDRESS), name);
    pushHandle(e.ZOWNER, e.ZADDRESS.toLowerCase());
  }
  for (const p of phones) {
    if (!p.ZFULLNUMBER || p.ZOWNER == null) continue;
    const name = nameFromRow(recordsByPk.get(p.ZOWNER));
    if (name) handleToName.set(canonHandle(p.ZFULLNUMBER), name);
    // Store the canonical phone tail as the lookup-form handle. We don't keep
    // the raw E.164 — chat.db will give us E.164, and we canonicalize at
    // lookup time.
    pushHandle(p.ZOWNER, canonHandle(p.ZFULLNUMBER));
  }

  for (const [pk, handles] of handlesPerRecord) {
    const name = nameFromRow(recordsByPk.get(pk));
    if (!name) continue;
    nameIndex.push({ lower_name: name.toLowerCase(), handles });
  }
}

export function resolveHandle(handleId: string): string | null {
  load();
  return handleToName.get(canonHandle(handleId)) ?? null;
}

export function resolveMany(handleIds: readonly string[]): Map<string, string | null> {
  load();
  const out = new Map<string, string | null>();
  for (const h of handleIds) out.set(h, handleToName.get(canonHandle(h)) ?? null);
  return out;
}

// Given a substring like "Catesby", return the canonicalized handle strings
// (canonical phone tails + lowercased emails) belonging to contacts whose
// name contains that substring. Callers use this list to widen a chat.db
// query that would otherwise only match against the raw handle string.
export function findHandlesByContactName(filter: string): string[] {
  load();
  if (!filter) return [];
  const lower = filter.toLowerCase();
  const out = new Set<string>();
  for (const entry of nameIndex) {
    if (entry.lower_name.includes(lower)) {
      for (const h of entry.handles) out.add(h);
    }
  }
  return [...out];
}

// For tests / forced cache invalidation.
export function _resetContactsCache(): void {
  loaded = false;
  handleToName = new Map();
  nameIndex = [];
}

// Test seam: inject contacts data directly, bypassing the AddressBook
// SQLite read. Marks the loader as "already loaded" so subsequent calls
// don't try to read AddressBook over the injected state.
export function _setContactsForTesting(
  handles: ReadonlyMap<string, string>,
  names: { lower_name: string; handles: string[] }[]
): void {
  loaded = true;
  handleToName = new Map(handles);
  nameIndex = names.map((e) => ({ lower_name: e.lower_name, handles: [...e.handles] }));
}

// Public accessor for the canonicalization rule, exposed so the
// `imessage_mcp_health_check` diagnostic tool can show callers exactly
// what their handle string canonicalizes to. The rule itself stays
// private — this just publishes the result for inspection.
export function canonHandlePublic(s: string): string {
  return canonHandle(s);
}

export type DbOpenStatus = "ok" | "permission_denied" | "not_found" | "error";

export interface AddressBookDiagnostic {
  db_path: string | null;
  db_path_exists: boolean;
  open_status: DbOpenStatus;
  open_error?: string;
  contacts_loaded: number;
}

// Classify a thrown error from `new Database(path, { readonly: true })`
// or a filesystem read. macOS surfaces FDA denial as EACCES on the file
// open; bun:sqlite tends to surface the same as a SQLite open failure
// with "permission denied" / "unable to open" in the message. ENOENT
// only appears if the file genuinely isn't there.
function classifyDbError(err: unknown): { status: DbOpenStatus; message: string } {
  const e = err as NodeJS.ErrnoException & { message?: string };
  const code = e?.code ?? "";
  const msg = (e?.message ?? String(err)).toLowerCase();
  if (
    code === "EACCES" ||
    code === "EPERM" ||
    e?.errno === -13 ||
    msg.includes("permission denied") ||
    msg.includes("operation not permitted") ||
    msg.includes("unable to open")
  ) {
    return { status: "permission_denied", message: e?.message ?? String(err) };
  }
  if (code === "ENOENT" || msg.includes("no such file")) {
    return { status: "not_found", message: e?.message ?? String(err) };
  }
  return { status: "error", message: e?.message ?? String(err) };
}

// Run the AddressBook open + bulk-load probe and report what happened.
// Resets the cache first so the result reflects current TCC state — this
// is intended for one-off diagnostic calls, not the hot path. Production
// `resolveHandle` keeps using the cached map.
export function getAddressBookDiagnostic(): AddressBookDiagnostic {
  const db_path = findAddressBookDb();
  const db_path_exists = db_path != null && existsSync(db_path);

  if (!db_path) {
    return {
      db_path: null,
      db_path_exists: false,
      open_status: "not_found",
      open_error: "findAddressBookDb returned null (no Sources/* match and top-level path missing or unreadable)",
      contacts_loaded: 0,
    };
  }

  // Try to open the DB directly so we can distinguish "FDA missing" from
  // "file missing" from "schema mismatch". This is a parallel probe — it
  // does NOT replace the bulk loader. If it succeeds, we then run the
  // real load() to get the contact count.
  let db: Database;
  try {
    db = new Database(db_path, { readonly: true });
    db.exec("PRAGMA query_only = ON;");
    db.close();
  } catch (err) {
    const { status, message } = classifyDbError(err);
    return {
      db_path,
      db_path_exists,
      open_status: status,
      open_error: message,
      contacts_loaded: 0,
    };
  }

  // Open succeeded. Force a fresh load so contacts_loaded reflects right-
  // now state (FDA could have been granted between server start and now).
  _resetContactsCache();
  try {
    load();
  } catch (err) {
    const { status, message } = classifyDbError(err);
    return {
      db_path,
      db_path_exists,
      open_status: status,
      open_error: message,
      contacts_loaded: 0,
    };
  }

  return {
    db_path,
    db_path_exists,
    open_status: "ok",
    contacts_loaded: handleToName.size,
  };
}
