// Send audit log + daily-cap enforcement.
//
// Every successful AppleScript send appends one JSON-line record to
// ~/.imessage-mcp/send-audit.log. The same file is read on each
// send to enforce a hard daily cap (a circuit breaker against
// runaway agents / prompt-injection blast attacks).
//
// Log format (one JSON object per line):
//   {"ts":"2026-05-14T22:31:28.173Z","draft_id":"...","to_handle":"...",
//    "body_sha256":"...","service":"iMessage"}
//
// `body_sha256` lets you audit "did the message that went out match
// what the user reviewed?" without storing the body content in plaintext
// in the log. The drafts dir already has bodies in 0600 JSONs; this log
// is for cross-referencing, not as the body store.
//
// The daily cap is intentionally simple: count log entries whose `ts`
// falls within the current UTC day (00:00:00Z → 23:59:59Z). UTC is
// used to avoid DST seams. Cap is configurable via env var
// IMESSAGE_DAILY_SEND_CAP (default 50). Setting it to 0 disables the
// check.

import { mkdirSync, existsSync, appendFileSync, readFileSync, lstatSync, chmodSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { createHash } from "node:crypto";

const DEFAULT_CAP = 50;

function auditDirPath(): string {
  return join(homedir(), ".imessage-mcp");
}

function auditLogPath(): string {
  return join(auditDirPath(), "send-audit.log");
}

let testOverridePath: string | null = null;

// Test seam: redirect audit log to a tmp file without touching $HOME.
export function _setAuditLogPathForTesting(path: string | null): void {
  testOverridePath = path;
}

function logPath(): string {
  return testOverridePath ?? auditLogPath();
}

function ensureDir(): void {
  const d = testOverridePath ? join(testOverridePath, "..") : auditDirPath();
  // Symlink defense: refuse if either the audit dir itself OR its parent
  // (one level up from `~/.imessage-mcp`, i.e. `$HOME`) has been replaced
  // with a symlink that would redirect our log writes. Parallel to the
  // drafts-side guard in storage/drafts.ts. We don't walk past the
  // immediate parent — `$HOME` itself being a symlink is the user's
  // problem, not ours to enforce. Using lstatSync directly (not
  // existsSync+lstatSync) because existsSync follows symlinks and would
  // return false for a dangling-symlink parent, skipping the guard.
  const parent = join(d, "..");
  try {
    if (lstatSync(parent).isSymbolicLink()) {
      throw new Error(`audit parent directory is a symlink, refusing to use: ${parent}`);
    }
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code !== "ENOENT") throw e;
  }
  if (existsSync(d)) {
    if (lstatSync(d).isSymbolicLink()) {
      throw new Error(`audit directory is a symlink, refusing to use: ${d}`);
    }
    return;
  }
  mkdirSync(d, { recursive: true });
}

export interface AuditEntry {
  ts: string;
  draft_id: string;
  to_handle: string;
  body_sha256: string;
  service: "iMessage" | "SMS";
}

export function appendAudit(args: {
  draft_id: string;
  to_handle: string;
  body: string;
  service: "iMessage" | "SMS";
  ts?: Date;
}): AuditEntry {
  ensureDir();
  const entry: AuditEntry = {
    ts: (args.ts ?? new Date()).toISOString(),
    draft_id: args.draft_id,
    to_handle: args.to_handle,
    body_sha256: createHash("sha256").update(args.body, "utf8").digest("hex"),
    service: args.service,
  };
  const path = logPath();
  appendFileSync(path, JSON.stringify(entry) + "\n", { mode: 0o600 });
  // `mode` on appendFileSync only applies on file CREATION. If a same-UID
  // attacker pre-created the log with 0o644 before our first append, every
  // subsequent append silently writes to a world-readable file — and this
  // log has `to_handle` (recipient phone/email) in cleartext on every
  // line. Re-chmod on every append to enforce.
  try {
    chmodSync(path, 0o600);
  } catch {
    // Best-effort. If chmod fails (network FS, exotic ACL), continue —
    // the append already succeeded and we don't want bookkeeping noise.
  }
  return entry;
}

// Did the audit log record a send for this draft id? Used as a second
// source of truth alongside `Draft.sent_at` to gate duplicate sends — if
// a previous run crashed between appendAudit and markDraftSent, the
// on-disk draft would say not-yet-sent but the audit would have the
// record. Without this check, a retry would fire AppleScript again and
// the recipient would get the message twice.
export function wasSentInAudit(draftId: string): boolean {
  return readAudit().some((e) => e.draft_id === draftId);
}

export function readAudit(): AuditEntry[] {
  const path = logPath();
  if (!existsSync(path)) return [];
  const raw = readFileSync(path, "utf8");
  const out: AuditEntry[] = [];
  for (const line of raw.split("\n")) {
    if (!line.trim()) continue;
    try {
      out.push(JSON.parse(line) as AuditEntry);
    } catch {
      // Skip malformed lines silently. The file is owner-only-writable
      // so the only way to land a bad line is local-disk corruption.
    }
  }
  return out;
}

// Count sends in the UTC day containing `now`. Cheap because the log is
// small (50/day × 365 days = ~18k lines = ~2MB/year worst case).
export function countSendsInCurrentDay(now: Date = new Date()): number {
  const startOfDay = new Date(Date.UTC(
    now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate(), 0, 0, 0, 0
  )).toISOString();
  return readAudit().filter((e) => e.ts >= startOfDay).length;
}

export function dailySendCap(): number {
  const raw = process.env["IMESSAGE_DAILY_SEND_CAP"];
  if (raw == null) return DEFAULT_CAP;
  const n = Number(raw);
  if (!Number.isFinite(n) || n < 0) return DEFAULT_CAP;
  return Math.floor(n);
}

// Returns null if under cap; an error message if at/over cap.
export function checkDailyCap(now: Date = new Date()): string | null {
  const cap = dailySendCap();
  if (cap === 0) return null; // 0 means "disabled"
  const count = countSendsInCurrentDay(now);
  if (count >= cap) {
    return `daily send cap reached (${count}/${cap} sends today UTC). ` +
           `Adjust via IMESSAGE_DAILY_SEND_CAP env var, or wait until ${nextResetIso(now)}.`;
  }
  return null;
}

function nextResetIso(now: Date): string {
  const next = new Date(Date.UTC(
    now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate() + 1, 0, 0, 0, 0
  ));
  return next.toISOString();
}
