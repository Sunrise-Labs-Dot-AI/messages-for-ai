import { z } from "zod";

const TWO_YEARS_MS = 2 * 365 * 24 * 60 * 60 * 1000;

const iso8601 = z
  .string()
  .refine((s) => !Number.isNaN(Date.parse(s)), { message: "must be a valid ISO-8601 timestamp" });

const sinceNotDeepHistory = iso8601.refine(
  (s) => Date.now() - Date.parse(s) <= TWO_YEARS_MS,
  { message: "since is older than 2 years; deep history requires an explicit opt-in flag (not yet supported)" }
);

const contactFilter = z.string().min(2, "contact_filter must be at least 2 characters");

// Raw shapes — passed to MCP `inputSchema`. The SDK validates with these and
// passes typed args to handlers; cross-field rules (e.g. "since OR contact_filter")
// are checked inline in the handler, where we can return an actionable error.

export const ListThreadsShape = {
  limit: z.number().int().min(1).max(100).default(25),
  since: sinceNotDeepHistory.optional(),
  before: iso8601.optional(),
  contact_filter: contactFilter.optional(),
} as const;

export const GetThreadShape = {
  thread_id: z.number().int().positive(),
  limit: z.number().int().min(1).max(200).default(50),
  before: iso8601.optional(),
} as const;

export const SearchShape = {
  query: z.string().min(2, "query must be at least 2 characters"),
  since: sinceNotDeepHistory.optional(),
  contact_filter: contactFilter.optional(),
  limit: z.number().int().min(1).max(100).default(25),
} as const;

export const StageDraftShape = {
  to_handle: z
    .string()
    .min(1)
    .refine((s) => /@/.test(s) || /^\+?\d[\d\s\-().]{5,}$/.test(s), {
      message: "to_handle must look like an email address or phone number",
    }),
  body: z.string().min(1).max(20_000),
  in_reply_to_thread_id: z.number().int().positive().optional(),
  // Short human-readable provenance label. Shown verbatim in the menu
  // bar app's draft review UI so a reviewer can tell which agent or
  // context staged the draft. Free-form; the agent should set it to
  // something the human will actually find informative, e.g.
  // "Claude Desktop / morning triage" or
  // "Claude Code in personal-assistant repo".
  source: z.string().min(1).max(200).optional(),
} as const;

export const ListDraftsShape = {
  limit: z.number().int().min(1).max(100).default(25),
} as const;

export const GetDraftShape = {
  draft_id: z.string().uuid(),
} as const;

export const DiscardDraftShape = {
  draft_id: z.string().uuid(),
} as const;

export const SendDraftShape = {
  draft_id: z.string().uuid(),
} as const;

export const CurrentTimeShape = {} as const;

export function requireSinceOrContactFilter(args: { since?: string; contact_filter?: string }): string | null {
  if (!args.since && !args.contact_filter) {
    return "either 'since' (ISO-8601, within 2 years) or 'contact_filter' (>=2 chars) is required";
  }
  return null;
}
