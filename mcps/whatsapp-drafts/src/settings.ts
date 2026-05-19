// User-editable settings at ~/.whatsapp-mcp/settings.json.
//
// Validated by Zod on EVERY read (no cache). Fail-closed: a corrupt or
// missing-but-permission-denied settings file → sends refused. A
// genuinely missing file → defaults written and used (first run is fine).
//
// Why no cache: the user may toggle `require_approval` mid-session.
// Re-reading on every send is cheap (one small JSON file) and the
// surprise factor of caching is worse than the cost.

import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { z } from "zod";

import { PATHS } from "./paths.ts";

export const SettingsSchema = z.object({
  /** When true, MCP-side send is blocked entirely; only the menu bar
   *  app's hold-to-fire path can flip a draft to `approved`. */
  require_approval: z.boolean().default(true),

  /** Max sends per UTC day. */
  daily_cap: z.number().int().positive().max(10_000).default(50),

  /** Minimum age (ms) a draft must be before it can be sent. Forces a
   *  multi-turn hand-off; defeats single-turn stage+send attacks. */
  min_staged_age_ms: z.number().int().min(0).max(60 * 60 * 1000).default(5000),

  /** Minimum delay between consecutive sends (ms), with ±500ms jitter
   *  applied at send time. Defeats bursty automated-client patterns. */
  min_inter_send_ms: z.number().int().min(0).max(60 * 1000).default(2000),

  /** Max sends in any rolling 60s window. */
  max_burst_in_60s: z.number().int().positive().max(1000).default(5),

  /** Drafts older than this are swept by the daemon's hourly cron. */
  draft_ttl_days: z.number().int().positive().max(365).default(7),

  /** Messages in messages.db older than this are swept daily at 03:00. */
  message_retention_days: z.number().int().positive().max(3650).default(90),
}).strict();

export type Settings = z.infer<typeof SettingsSchema>;

/** Defaults — exported so callers can reason about what 'fresh' looks like. */
export const DEFAULT_SETTINGS: Settings = SettingsSchema.parse({});

export class SettingsError extends Error {
  constructor(message: string, public path: string) {
    super(message);
    this.name = "SettingsError";
  }
}

/**
 * Read settings. Returns parsed object or throws SettingsError.
 *
 * - File missing → write defaults, return them
 * - File present but unreadable (perm denied, IO error) → throw
 * - File present but malformed JSON → throw
 * - File present, valid JSON, schema mismatch → throw with detail
 */
export function readSettings(): Settings {
  const path = PATHS.settingsJson;
  if (!existsSync(path)) {
    writeFileSync(path, JSON.stringify(DEFAULT_SETTINGS, null, 2), { mode: 0o600 });
    return DEFAULT_SETTINGS;
  }
  let raw: string;
  try {
    raw = readFileSync(path, "utf8");
  } catch (e) {
    throw new SettingsError(`could not read ${path}: ${(e as Error).message}`, path);
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch (e) {
    throw new SettingsError(`${path}: invalid JSON — ${(e as Error).message}`, path);
  }
  const result = SettingsSchema.safeParse(parsed);
  if (!result.success) {
    const messages = result.error.errors
      .map((e) => `${e.path.join(".")}: ${e.message}`)
      .join("; ");
    throw new SettingsError(`${path}: schema validation failed — ${messages}`, path);
  }
  return result.data;
}

/** Test seam: tests may pre-write a settings file in a temp dir. */
export function writeSettings(s: Settings): void {
  writeFileSync(PATHS.settingsJson, JSON.stringify(s, null, 2), { mode: 0o600 });
}
