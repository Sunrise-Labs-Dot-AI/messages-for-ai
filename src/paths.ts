// Canonical filesystem paths under ~/.whatsapp-mcp/.
// Centralized so storage, daemon, and MCP binary all agree.

import { homedir } from "node:os";
import { join } from "node:path";

const HOME = process.env.WHATSAPP_MCP_HOME ?? join(homedir(), ".whatsapp-mcp");

export const PATHS = {
  /** Root directory — mode 0700 at install time. */
  root: HOME,
  /** Unix socket the daemon listens on. */
  daemonSock: join(HOME, "daemon.sock"),
  /** PID lock file (single-instance guard). */
  daemonPid: join(HOME, "daemon.pid"),
  /** Baileys session credentials. AES-GCM wrapped with Keychain key. */
  sessionDb: join(HOME, "session.db"),
  /** Plaintext message cache (symmetric with iMessage chat.db). */
  messagesDb: join(HOME, "messages.db"),
  /** Send audit + atomic rate-limit accounting. */
  auditDb: join(HOME, "audit.db"),
  /** Staged drafts (JSON files, mode 0600). */
  draftsDir: join(HOME, "drafts"),
  /** User-editable settings (Zod-validated; fail-closed on parse error). */
  settingsJson: join(HOME, "settings.json"),
  /** Recovery sentinel — written on loggedOut, blocks daemon auto-restart. */
  loggedOutSentinel: join(HOME, "LOGGED_OUT"),
} as const;
