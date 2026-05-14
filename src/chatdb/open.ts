import { Database } from "bun:sqlite";
import { homedir } from "node:os";
import { join } from "node:path";

const CHAT_DB_PATH = join(homedir(), "Library", "Messages", "chat.db");

let dbInstance: Database | null = null;

export function openChatDb(): Database {
  if (dbInstance) return dbInstance;
  const db = new Database(CHAT_DB_PATH, { readonly: true });
  db.exec("PRAGMA query_only = ON;");
  dbInstance = db;
  return db;
}

// Test seam: inject a pre-built in-memory SQLite handle so unit tests can
// exercise the query layer without macOS TCC / Full Disk Access. Production
// code paths never call this — it's only wired from `*.test.ts`.
export function _setChatDbForTesting(db: Database | null): void {
  dbInstance = db;
}

export function chatDbPath(): string {
  return CHAT_DB_PATH;
}

// Apple Cocoa epoch: 2001-01-01 00:00:00 UTC, in unix-ms terms.
const APPLE_EPOCH_OFFSET_MS = 978307200_000;

// `message.date` is nanoseconds since the Apple epoch on macOS High Sierra+,
// and seconds on older versions. The nanosecond values are huge (~1e18) and
// the second values are tiny (~7e8), so the magnitude check is reliable.
export function appleDateToIsoUtc(rawDate: number | bigint | null): string | null {
  if (rawDate == null) return null;
  const n = typeof rawDate === "bigint" ? Number(rawDate) : rawDate;
  if (!Number.isFinite(n) || n <= 0) return null;
  const unixMs = n > 1e15 ? Math.round(n / 1_000_000) + APPLE_EPOCH_OFFSET_MS : n * 1000 + APPLE_EPOCH_OFFSET_MS;
  return new Date(unixMs).toISOString();
}

// Inverse: ISO-8601 → Apple-epoch nanoseconds, for parameterized `since` filters
// against post-High-Sierra rows. Pre-High-Sierra rows compare unfavorably against
// a large `since` (their date < threshold), which is the safe default — they're
// older than any realistic `since` value anyway.
export function isoUtcToAppleDateNs(iso: string): bigint {
  const unixMs = Date.parse(iso);
  if (Number.isNaN(unixMs)) throw new Error(`invalid ISO-8601 timestamp: ${iso}`);
  return BigInt(unixMs - APPLE_EPOCH_OFFSET_MS) * 1_000_000n;
}
