import { mkdirSync, readdirSync, readFileSync, writeFileSync, unlinkSync, statSync, existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";

const DRAFTS_DIR = join(homedir(), ".imessage-mcp", "drafts");

export interface Draft {
  id: string;
  to_handle: string;
  body: string;
  in_reply_to_thread_id: number | null;
  staged_at: string;
  sent_at: string | null;
  send_service: "iMessage" | "SMS" | null;
}

function ensureDir(): void {
  if (!existsSync(DRAFTS_DIR)) mkdirSync(DRAFTS_DIR, { recursive: true });
}

function draftPath(id: string): string {
  return join(DRAFTS_DIR, `${id}.json`);
}

export interface StageDraftArgs {
  to_handle: string;
  body: string;
  in_reply_to_thread_id?: number | null;
}

export function stageDraft(args: StageDraftArgs): { draft: Draft; path: string } {
  ensureDir();
  const draft: Draft = {
    id: randomUUID(),
    to_handle: args.to_handle,
    body: args.body,
    in_reply_to_thread_id: args.in_reply_to_thread_id ?? null,
    staged_at: new Date().toISOString(),
    sent_at: null,
    send_service: null,
  };
  const path = draftPath(draft.id);
  writeFileSync(path, JSON.stringify(draft, null, 2), { mode: 0o600 });
  return { draft, path };
}

export function listDrafts(limit: number): Draft[] {
  ensureDir();
  const entries = readdirSync(DRAFTS_DIR)
    .filter((f) => f.endsWith(".json"))
    .map((f) => {
      const p = join(DRAFTS_DIR, f);
      return { path: p, mtime: statSync(p).mtimeMs };
    })
    .sort((a, b) => b.mtime - a.mtime)
    .slice(0, limit);
  const out: Draft[] = [];
  for (const e of entries) {
    try {
      const normalized = normalizeDraft(JSON.parse(readFileSync(e.path, "utf8")) as Partial<Draft>);
      if (normalized) out.push(normalized);
    } catch {
      // Skip corrupt entries silently — the user can `rm` them by hand.
    }
  }
  return out;
}

export function getDraft(id: string): Draft | null {
  ensureDir();
  const path = draftPath(id);
  if (!existsSync(path)) return null;
  try {
    const raw = JSON.parse(readFileSync(path, "utf8")) as Partial<Draft>;
    return normalizeDraft(raw);
  } catch {
    return null;
  }
}

// Backfill fields added in later schema revisions so callers can rely on
// the current Draft shape regardless of when the file was written.
function normalizeDraft(raw: Partial<Draft>): Draft | null {
  if (!raw || !raw.id || !raw.to_handle || raw.body == null || !raw.staged_at) return null;
  return {
    id: raw.id,
    to_handle: raw.to_handle,
    body: raw.body,
    in_reply_to_thread_id: raw.in_reply_to_thread_id ?? null,
    staged_at: raw.staged_at,
    sent_at: raw.sent_at ?? null,
    send_service: raw.send_service ?? null,
  };
}

// Mark a draft as sent. Returns the updated draft, or null if not found.
// Older draft files written before the sent_at field existed will be migrated
// in-place on read (see getDraft), so this just overwrites in the current
// schema.
export function markDraftSent(id: string, sentAt: string, service: "iMessage" | "SMS"): Draft | null {
  const existing = getDraft(id);
  if (!existing) return null;
  const updated: Draft = { ...existing, sent_at: sentAt, send_service: service };
  writeFileSync(draftPath(id), JSON.stringify(updated, null, 2), { mode: 0o600 });
  return updated;
}

export function discardDraft(id: string): boolean {
  ensureDir();
  const path = draftPath(id);
  if (!existsSync(path)) return false;
  unlinkSync(path);
  return true;
}

export function draftsDir(): string {
  return DRAFTS_DIR;
}
