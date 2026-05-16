// Shared Zod validators. Mirrors imessage-mcp/src/schema.ts patterns.

import { z } from "zod";

const TWO_YEARS_MS = 1000 * 60 * 60 * 24 * 365 * 2;

/** ISO-8601 datetime, must be within the last 2 years and not in the future. */
const SinceIso = z.string().refine(
  (s) => {
    const t = Date.parse(s);
    if (!Number.isFinite(t)) return false;
    const now = Date.now();
    return t >= now - TWO_YEARS_MS && t <= now;
  },
  { message: "must be ISO-8601 within the last 2 years, not in the future" },
);

const ContactFilter = z.string().min(2, "contact_filter must be at least 2 chars");

/** Either since OR contact_filter is required — prevents unbounded history dumps. */
function eitherFilter<T extends { since?: string; contact_filter?: string }>(arg: T): boolean {
  return arg.since != null || (arg.contact_filter != null && arg.contact_filter.length > 0);
}
const eitherFilterErr = { message: "either `since` (ISO-8601) or `contact_filter` (≥2 chars) is required" };

// Split each input into an object shape (for MCP tool registration's
// `.shape` requirement) and a fully-refined schema (for validation).
// `.refine()` returns ZodEffects, which doesn't have `.shape` — so we
// can't compress these into one expression.

const ListThreadsObj = z.object({
  since: SinceIso.optional(),
  contact_filter: ContactFilter.optional(),
  limit: z.number().int().positive().max(500).optional(),
});
export const ListThreadsShape = ListThreadsObj.shape;
export const ListThreadsInput = ListThreadsObj.refine(eitherFilter, eitherFilterErr);

const GetThreadObj = z.object({
  thread_jid: z.string().min(1),
  before_ts: z.number().int().positive().optional(),
  limit: z.number().int().positive().max(500).optional(),
});
export const GetThreadShape = GetThreadObj.shape;
export const GetThreadInput = GetThreadObj;

const SearchObj = z.object({
  query: z.string().min(2, "query must be at least 2 chars"),
  since: SinceIso.optional(),
  contact_filter: ContactFilter.optional(),
  limit: z.number().int().positive().max(500).optional(),
});
export const SearchShape = SearchObj.shape;
export const SearchInput = SearchObj.refine(eitherFilter, eitherFilterErr);

const GetMessageFullObj = z.object({
  thread_jid: z.string().min(1),
  message_id: z.string().min(1),
});
export const GetMessageFullShape = GetMessageFullObj.shape;
export const GetMessageFullInput = GetMessageFullObj;

// WhatsApp JID: either a phone-number user JID like "12025550001@s.whatsapp.net"
// or a group JID like "120363xxxx@g.us". We don't try to enforce the full
// shape — Baileys returns errors for malformed JIDs anyway — but we require
// a non-empty string with no whitespace and the "@" separator.
const WhatsAppJid = z.string().min(1).regex(/^[^@\s]+@[^@\s]+$/, "expected a WhatsApp JID like 12025550001@s.whatsapp.net or 12036xx@g.us");

const StageDraftObj = z.object({
  to_handle: WhatsAppJid,
  body: z.string().min(1, "body must not be empty").max(60_000, "body too long"),
  source: z.string().optional(),
});
export const StageDraftShape = StageDraftObj.shape;
export const StageDraftInput = StageDraftObj;

const DraftIdObj = z.object({ draft_id: z.string().uuid("draft_id must be a UUID") });
export const DraftIdShape = DraftIdObj.shape;
export const DraftIdInput = DraftIdObj;

export type ListThreadsArgs = z.infer<typeof ListThreadsInput>;
export type GetThreadArgs = z.infer<typeof GetThreadInput>;
export type SearchArgs = z.infer<typeof SearchInput>;
export type GetMessageFullArgs = z.infer<typeof GetMessageFullInput>;

export function isoToMs(iso: string | undefined): number | undefined {
  if (iso == null) return undefined;
  const t = Date.parse(iso);
  return Number.isFinite(t) ? t : undefined;
}
