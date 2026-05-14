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
  const sourcesRoot = join(homedir(), "Library", "Application Support", "AddressBook", "Sources");
  if (existsSync(sourcesRoot)) {
    for (const source of readdirSync(sourcesRoot)) {
      const candidate = join(sourcesRoot, source, "AddressBook-v22.abcddb");
      if (existsSync(candidate)) return candidate;
    }
  }
  const top = join(homedir(), "Library", "Application Support", "AddressBook", "AddressBook-v22.abcddb");
  return existsSync(top) ? top : null;
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
