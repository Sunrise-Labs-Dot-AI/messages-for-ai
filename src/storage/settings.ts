// User-controllable settings shared between the MCP server and the
// companion menu bar app. Single-key file today (require_approval), but
// the schema is open-ended so we can add more knobs without breaking
// older builds — unknown keys are ignored, missing keys fall back to
// safe defaults.
//
// File: ~/.imessage-mcp/settings.json (mode 0600).
//
// Reads happen on every MCP send so toggling the flag in the menu bar
// app takes effect immediately, no MCP-client restart needed. Writes
// happen only from the menu bar app; the MCP server is read-only.

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export interface Settings {
  // When true (default), the MCP `send_imessage_draft` tool refuses to
  // send and instructs the caller to use the menu bar app instead. This
  // is the strongest enforcement of the draft-review property:
  // every send must pass through human eyes.
  require_approval: boolean;
}

const DEFAULTS: Settings = {
  require_approval: true,
};

function settingsDirPath(): string {
  return testDirOverride ?? join(homedir(), ".imessage-mcp");
}

function settingsFilePath(): string {
  return join(settingsDirPath(), "settings.json");
}

let testDirOverride: string | null = null;

export function _setSettingsDirForTesting(dir: string | null): void {
  testDirOverride = dir;
}

function ensureDir(): void {
  const d = settingsDirPath();
  if (!existsSync(d)) mkdirSync(d, { recursive: true });
}

// Load with graceful fallback. A missing or corrupt file returns the
// safe defaults — important because the MCP server runs before the
// menu bar app has had a chance to write the file on a fresh install.
export function loadSettings(): Settings {
  const path = settingsFilePath();
  if (!existsSync(path)) return { ...DEFAULTS };
  try {
    const raw = JSON.parse(readFileSync(path, "utf8")) as Partial<Settings>;
    return {
      require_approval: typeof raw.require_approval === "boolean" ? raw.require_approval : DEFAULTS.require_approval,
    };
  } catch {
    return { ...DEFAULTS };
  }
}

// Convenience: just the one boolean. Read fresh from disk each call —
// no caching — so toggling in the menu bar takes effect on the next
// send without restarting any process.
export function requireApproval(): boolean {
  return loadSettings().require_approval;
}

// Used from tests; production writes happen from the Swift menu bar app.
export function _saveSettingsForTesting(settings: Settings): void {
  ensureDir();
  writeFileSync(settingsFilePath(), JSON.stringify(settings, null, 2), { mode: 0o600 });
}
