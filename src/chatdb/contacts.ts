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
import { readContactsSidecar } from "../storage/contacts-cache.ts";

let loaded = false;
let handleToName = new Map<string, string>(); // canonicalized handle -> name
let nameIndex: { lower_name: string; handles: string[] }[] = []; // for substring search

// Return EVERY AddressBook database we can find. On a multi-account Mac
// (iCloud Contacts + Google + Exchange + local "On My Mac"), each source
// stores its contacts in a separate Sources/{uuid}/AddressBook-v22.abcddb
// file. The previous version of this function returned only the first
// match, which routinely missed iCloud contacts on machines where the
// local source happened to be enumerated first.
//
// We also include the top-level AddressBook-v22.abcddb when present — it
// historically held the consolidated DB before macOS split into per-source
// files, and some users still have a populated copy there.
//
// IMPORTANT: the Sources-scan try/catch is intentionally separate from the
// outer guard. readdirSync(sourcesRoot) raises EPERM when TCC hasn't yet
// granted access to that specific sub-path (even when FDA is granted for
// the top-level AddressBook dir). Catching the inner error lets us fall
// through to the top-level path rather than short-circuiting to [].
function findAddressBookDbs(): string[] {
  const out: string[] = [];
  try {
    const sourcesRoot = join(homedir(), "Library", "Application Support", "AddressBook", "Sources");
    if (existsSync(sourcesRoot)) {
      try {
        for (const source of readdirSync(sourcesRoot)) {
          const candidate = join(sourcesRoot, source, "AddressBook-v22.abcddb");
          if (existsSync(candidate)) out.push(candidate);
        }
      } catch {
        // Sources scan failed (EPERM or similar) — fall through to top-level path.
      }
    }
    const top = join(homedir(), "Library", "Application Support", "AddressBook", "AddressBook-v22.abcddb");
    if (existsSync(top)) out.push(top);
  } catch {
    // Outer fs surface failed entirely — return whatever we collected so far.
  }
  return out;
}

// Single-path accessor kept for backward compat with callers that just
// want a "primary" DB to display in a diagnostic. Returns the first DB
// from `findAddressBookDbs()` or null when there are none.
function findAddressBookDb(): string | null {
  return findAddressBookDbs()[0] ?? null;
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

// Per-DB load report, surfaced to `getAddressBookDiagnostic` so the
// menu bar / health_check tool can show "loaded 3 DBs — local + iCloud
// + Google — 412 contacts total" rather than a flat number.
interface PerDbReport {
  path: string;
  open_status: DbOpenStatus;
  open_error?: string;
  records: number;
  emails: number;
  phones: number;
  contacts_contributed: number; // new handle keys added by THIS DB
}

let lastLoadReport: PerDbReport[] = [];

function loadOneDb(path: string): PerDbReport {
  let db: Database;
  try {
    db = new Database(path, { readonly: true });
    db.exec("PRAGMA query_only = ON;");
  } catch (err) {
    const { status, message } = classifyDbError(err);
    return {
      path,
      open_status: status,
      open_error: message,
      records: 0,
      emails: 0,
      phones: 0,
      contacts_contributed: 0,
    };
  }

  let records: RecordRow[];
  let emails: EmailRow[];
  let phones: PhoneRow[];
  try {
    records = db.query<RecordRow, []>("SELECT Z_PK, ZFIRSTNAME, ZLASTNAME, ZORGANIZATION FROM ZABCDRECORD").all();
    emails = db.query<EmailRow, []>("SELECT ZOWNER, ZADDRESS FROM ZABCDEMAILADDRESS").all();
    phones = db.query<PhoneRow, []>("SELECT ZOWNER, ZFULLNUMBER FROM ZABCDPHONENUMBER").all();
  } catch (err) {
    try { db.close(); } catch { /* ignore */ }
    const { status, message } = classifyDbError(err);
    return {
      path,
      open_status: status,
      open_error: message,
      records: 0,
      emails: 0,
      phones: 0,
      contacts_contributed: 0,
    };
  }
  try { db.close(); } catch { /* ignore */ }

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

  const sizeBefore = handleToName.size;
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

  return {
    path,
    open_status: "ok",
    records: records.length,
    emails: emails.length,
    phones: phones.length,
    contacts_contributed: handleToName.size - sizeBefore,
  };
}

// Tracks which source actually populated the in-memory map on the most
// recent load(). Surfaced via getAddressBookDiagnostic so the health
// tool can show "sidecar" vs "sqlite_fallback" vs "none".
let lastLoadSource: "sidecar" | "sqlite_fallback" | "none" | "test_seam" = "none";

function load(): void {
  if (loaded) return;
  loaded = true; // mark loaded even on failure to avoid retry storms

  // Primary path: contacts sidecar written by the Swift menu bar app
  // via CNContactStore. This is preferred because:
  //   - It sees CloudKit-only iCloud contacts that don't appear in
  //     the local AddressBook SQLite files.
  //   - It runs under NSContacts permission (native consent dialog),
  //     not FDA — so the menu bar can be granted access without the
  //     manual drag-into-System-Settings dance.
  //   - It survives MCP-binary rebuilds, which can lose their FDA
  //     grant if the codesign identifier shifts.
  const sidecar = readContactsSidecar();
  if (sidecar && sidecar.permission_status === "granted" && Object.keys(sidecar.handles).length > 0) {
    for (const [canon, name] of Object.entries(sidecar.handles)) {
      handleToName.set(canon, name);
    }
    lastLoadSource = "sidecar";
    lastLoadReport = []; // sqlite path didn't run
    process.stderr.write(
      `[contacts] loaded from sidecar: ${handleToName.size} contacts ` +
      `(written ${sidecar.generated_at} by ${sidecar.source})\n`
    );
    return;
  }

  // Fallback: bulk-load from AddressBook SQLite. Used when the sidecar
  // is missing (menu bar app not installed), unreadable, or empty (the
  // user denied Contacts permission to the menu bar app). Requires
  // Full Disk Access on this binary; will report empty maps without it.
  if (sidecar) {
    process.stderr.write(
      `[contacts] sidecar present but unusable (status=${sidecar.permission_status}, ` +
      `count=${Object.keys(sidecar.handles).length}); falling back to SQLite\n`
    );
  } else {
    process.stderr.write(
      `[contacts] no sidecar at ~/.imessage-mcp/contacts-cache.json; ` +
      `falling back to SQLite (install the menu bar app and grant Contacts permission to skip the FDA dependency)\n`
    );
  }

  const paths = findAddressBookDbs();
  const reports: PerDbReport[] = [];

  // Iterate every AddressBook DB and union the resulting handle→name
  // map. A user with iCloud + local + Google contacts has each source
  // in a separate Sources/{uuid}/AddressBook-v22.abcddb file, and
  // earlier versions of this loader returned only the first match —
  // which silently dropped everyone in the other sources.
  for (const path of paths) {
    reports.push(loadOneDb(path));
  }
  lastLoadReport = reports;
  lastLoadSource = handleToName.size > 0 ? "sqlite_fallback" : "none";

  // Stderr breadcrumb so the user can see what happened by tailing
  // ~/Library/Logs/Claude/mcp-server-imessage-mcp.log. Stays out of
  // stdout (which is reserved for JSON-RPC).
  if (reports.length > 0) {
    const summary = reports
      .map((r) => `${r.open_status === "ok" ? "ok" : `[${r.open_status}]`} ${r.path.replace(homedir(), "~")} (+${r.contacts_contributed})`)
      .join("; ");
    process.stderr.write(`[contacts] sqlite bulk-load: ${reports.length} db(s); ${handleToName.size} total contacts. ${summary}\n`);
  } else {
    process.stderr.write(`[contacts] sqlite bulk-load: no AddressBook databases found\n`);
  }
}

export function getLastContactsLoadSource(): "sidecar" | "sqlite_fallback" | "none" | "test_seam" {
  return lastLoadSource;
}

// Expose the last bulk-load report so the diagnostic tool can show
// per-DB stats (which DBs were found, which opened, contacts each
// contributed). Empty array before the first load() call.
export function getLastContactsLoadReport(): readonly PerDbReport[] {
  return lastLoadReport;
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
  lastLoadReport = [];
  lastLoadSource = "none";
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
  lastLoadSource = "test_seam";
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
  // Primary DB path for backward compat. First entry of `db_paths`.
  db_path: string | null;
  db_path_exists: boolean;
  // Every AddressBook DB the loader found. Multi-account Macs typically
  // have several Sources/{uuid}/AddressBook-v22.abcddb files (one per
  // CardDAV source: iCloud, Google, Exchange, "On My Mac") plus the
  // top-level path.
  db_paths: string[];
  // Open status for the PRIMARY DB. Aggregate state for callers that
  // just want a single yes/no; `per_db` has the breakdown.
  open_status: DbOpenStatus;
  open_error?: string;
  contacts_loaded: number;
  per_db: ReadonlyArray<{
    path: string;
    open_status: DbOpenStatus;
    open_error?: string;
    records: number;
    emails: number;
    phones: number;
    contacts_contributed: number;
  }>;
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
    // bun:sqlite (and the system libsqlite TCC authorizer hook on macOS)
    // surface FDA denial as the literal "authorization denied" error
    // message — verified empirically running this loader without FDA.
    // We also catch the older / generic SQLite phrasings here.
    msg.includes("authorization denied") ||
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

// Run the AddressBook bulk-load and report per-DB stats. Resets the
// cache first so the result reflects current TCC state — this is
// intended for one-off diagnostic calls, not the hot path. Production
// `resolveHandle` keeps using the cached map.
//
// The shape distinguishes "primary DB status" (back-compat for callers
// that just want a one-line yes/no) from `per_db` (the breakdown for
// multi-account Macs where iCloud + local + Google all live in
// separate files).
export function getAddressBookDiagnostic(): AddressBookDiagnostic {
  const db_paths = findAddressBookDbs();
  const primary = db_paths[0] ?? null;

  if (db_paths.length === 0) {
    return {
      db_path: null,
      db_path_exists: false,
      db_paths: [],
      open_status: "not_found",
      open_error: "findAddressBookDbs returned [] (no Sources/* match and top-level path missing or unreadable)",
      contacts_loaded: 0,
      per_db: [],
    };
  }

  // Force a fresh load so contacts_loaded reflects right-now state
  // (FDA could have been granted between server start and now).
  _resetContactsCache();
  load();

  const per_db = getLastContactsLoadReport();
  const primaryReport = per_db.find((r) => r.path === primary);
  const open_status: DbOpenStatus = primaryReport?.open_status ?? "error";
  const open_error = primaryReport?.open_error;

  return {
    db_path: primary,
    db_path_exists: primary != null && existsSync(primary),
    db_paths,
    open_status,
    open_error,
    contacts_loaded: handleToName.size,
    per_db,
  };
}
