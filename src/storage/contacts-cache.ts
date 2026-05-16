import { existsSync, readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

// Contacts sidecar — written by the Swift menu bar app via
// `CNContactStore`, read by this MCP binary. This is the primary source
// of truth for contact-name resolution because:
//
//   1. CNContactStore sees data Messages.app sees, including iCloud
//      contacts that are CloudKit-only and don't always write to the
//      local AddressBook SQLite files.
//
//   2. NSContacts permission has a proper native consent dialog
//      (CNContactStore.requestAccess), unlike Full Disk Access which
//      requires the user to manually drag the binary into a System
//      Settings pane.
//
//   3. Decoupling means a rebuilt MCP binary doesn't lose contact
//      resolution along with its TCC state — the menu bar app's
//      NSContacts grant survives independently.
//
// The MCP binary still has a direct-SQLite fallback (see load() in
// chatdb/contacts.ts) for users who haven't installed the menu bar app.

// Cached on first access. The TS side does NOT poll — Claude Desktop
// spawns a fresh MCP child often enough that the cache invalidates
// naturally. If we ever need live-refresh behavior, do an mtime check
// here at a 60-second interval rather than re-reading on every call.
function defaultSidecarPath(): string {
  return join(homedir(), ".imessage-mcp", "contacts-cache.json");
}

// On-disk schema. Bumping `version` is a breaking change requiring a
// matching update in the Swift exporter — keep the constant in sync
// with `kContactsCacheSchemaVersion` over there.
export const CONTACTS_CACHE_SCHEMA_VERSION = 1;

export interface ContactsSidecar {
  version: number;
  generated_at: string;          // ISO-8601
  source: string;                // "menubar-cnContactStore", etc.
  permission_status: "granted" | "denied" | "restricted" | "unknown";
  count: number;
  // Canonical handle → display name. Keys are already canonicalized
  // by the writer using the same rule as canonHandle in
  // chatdb/contacts.ts (last-10-digits for phones, lowercase for emails).
  handles: Record<string, string>;
}

export interface ContactsSidecarDiagnostic {
  path: string;
  exists: boolean;
  read_status: "ok" | "missing" | "stale_schema" | "parse_error" | "io_error";
  read_error?: string;
  mtime_iso?: string;
  age_seconds?: number;
  generated_at?: string;
  source?: string;
  permission_status?: string;
  count?: number;
}

// One-shot read of the sidecar. Returns null when the file doesn't
// exist or is unreadable — callers (the loader in chatdb/contacts.ts)
// fall back to SQLite in that case.
export function readContactsSidecar(): ContactsSidecar | null {
  const path = contactsCachePath();
  if (!existsSync(path)) return null;
  try {
    const raw = readFileSync(path, "utf8");
    const parsed = JSON.parse(raw) as Partial<ContactsSidecar>;
    if (
      typeof parsed.version !== "number" ||
      typeof parsed.handles !== "object" ||
      parsed.handles == null
    ) {
      return null;
    }
    if (parsed.version !== CONTACTS_CACHE_SCHEMA_VERSION) return null;
    return {
      version: parsed.version,
      generated_at: parsed.generated_at ?? "",
      source: parsed.source ?? "unknown",
      permission_status: (parsed.permission_status as ContactsSidecar["permission_status"]) ?? "unknown",
      count: parsed.count ?? Object.keys(parsed.handles).length,
      handles: parsed.handles as Record<string, string>,
    };
  } catch {
    // Atomic-write race or bad JSON. Caller falls back to SQLite.
    return null;
  }
}

// Diagnostic-friendly inspection without committing to a load. Used by
// the `imessage_mcp_health_check` tool to show "is the sidecar there?
// when was it written? how stale is it?"
export function getContactsSidecarDiagnostic(): ContactsSidecarDiagnostic {
  const path = contactsCachePath();
  if (!existsSync(path)) {
    return { path, exists: false, read_status: "missing" };
  }

  let mtime: Date;
  try {
    mtime = statSync(path).mtime;
  } catch (e) {
    return {
      path,
      exists: true,
      read_status: "io_error",
      read_error: (e as Error).message,
    };
  }

  let raw: string;
  try {
    raw = readFileSync(path, "utf8");
  } catch (e) {
    return {
      path,
      exists: true,
      read_status: "io_error",
      read_error: (e as Error).message,
      mtime_iso: mtime.toISOString(),
      age_seconds: Math.floor((Date.now() - mtime.getTime()) / 1000),
    };
  }

  let parsed: Partial<ContactsSidecar>;
  try {
    parsed = JSON.parse(raw) as Partial<ContactsSidecar>;
  } catch (e) {
    return {
      path,
      exists: true,
      read_status: "parse_error",
      read_error: (e as Error).message,
      mtime_iso: mtime.toISOString(),
      age_seconds: Math.floor((Date.now() - mtime.getTime()) / 1000),
    };
  }

  if (
    typeof parsed.version !== "number" ||
    parsed.version !== CONTACTS_CACHE_SCHEMA_VERSION ||
    typeof parsed.handles !== "object" ||
    parsed.handles == null
  ) {
    return {
      path,
      exists: true,
      read_status: "stale_schema",
      read_error: `expected version ${CONTACTS_CACHE_SCHEMA_VERSION}, got ${parsed.version ?? "(missing)"}`,
      mtime_iso: mtime.toISOString(),
      age_seconds: Math.floor((Date.now() - mtime.getTime()) / 1000),
      generated_at: parsed.generated_at,
      source: parsed.source,
    };
  }

  return {
    path,
    exists: true,
    read_status: "ok",
    mtime_iso: mtime.toISOString(),
    age_seconds: Math.floor((Date.now() - mtime.getTime()) / 1000),
    generated_at: parsed.generated_at,
    source: parsed.source,
    permission_status: parsed.permission_status,
    count: parsed.count ?? Object.keys(parsed.handles).length,
  };
}

// Test seam. Override the sidecar path so tests can use a tmp dir.
let pathOverride: string | null = null;
export function _setSidecarPathForTesting(p: string | null): void {
  pathOverride = p;
}

// Resolved sidecar path — honors test override. Exposed for the
// diagnostic path printout.
export function contactsCachePath(): string {
  return pathOverride ?? defaultSidecarPath();
}
