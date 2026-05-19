// Get-or-create the AES-256-GCM master key for session.db wrapping.
//
// Stored in macOS Keychain as a generic-password item. The first time
// the daemon runs against a fresh Keychain, it generates a random 256-bit
// key and stores it; subsequent runs retrieve it.
//
// macOS will prompt the user the FIRST TIME an unsigned binary tries to
// read the item ("whatsapp-daemon wants to use your confidential
// information..."). Clicking "Always Allow" suppresses the prompt
// forever for that exact binary path. When the daemon is code-signed
// for production release, the Keychain item should be re-created with
// `-T <signed-binary-path>` to skip the prompt entirely; this lands
// with the signing pipeline, not now.
//
// Failure modes (all fail-closed):
//   - `security` CLI not on PATH                      → throw
//   - Keychain locked / user denied access            → throw
//   - Stored key isn't a 32-byte base64 string        → throw
//
// On any throw, the daemon must refuse to start. The session would be
// unreadable without the key.

const SERVICE = "ai.sunriselabs.whatsapp-mcp";
const ACCOUNT = "session-wrap-key";

/** Generate 32 random bytes via Node's crypto module. */
function generateKey(): Buffer {
  const { randomBytes } = require("node:crypto") as typeof import("node:crypto");
  return randomBytes(32);
}

interface SpawnSyncResult {
  exitCode: number;
  stdout: Uint8Array;
  stderr: Uint8Array;
}

function runSecurity(args: string[], stdin?: string): SpawnSyncResult {
  const proc = Bun.spawnSync({
    cmd: ["security", ...args],
    stdin: stdin != null ? new TextEncoder().encode(stdin) : "ignore",
    stdout: "pipe",
    stderr: "pipe",
  });
  return {
    exitCode: proc.exitCode ?? -1,
    stdout: proc.stdout ?? new Uint8Array(),
    stderr: proc.stderr ?? new Uint8Array(),
  };
}

/** True if a key is already stored. */
function hasKey(): boolean {
  const r = runSecurity(["find-generic-password", "-s", SERVICE, "-a", ACCOUNT]);
  return r.exitCode === 0;
}

/** Read the stored key, decoding from base64. Throws if missing/malformed. */
function readKey(): Buffer {
  // `-w` flag prints just the secret payload to stdout.
  const r = runSecurity(["find-generic-password", "-s", SERVICE, "-a", ACCOUNT, "-w"]);
  if (r.exitCode !== 0) {
    const err = new TextDecoder().decode(r.stderr).trim();
    throw new Error(`Keychain read failed (${r.exitCode}): ${err || "user denied or item missing"}`);
  }
  const b64 = new TextDecoder().decode(r.stdout).trim();
  let raw: Buffer;
  try {
    raw = Buffer.from(b64, "base64");
  } catch {
    throw new Error("Keychain item is not valid base64");
  }
  if (raw.byteLength !== 32) {
    throw new Error(`Keychain key has wrong length: expected 32 bytes, got ${raw.byteLength}`);
  }
  return raw;
}

/** Write a key. Uses `-U` to update if already present (idempotent). */
function writeKey(key: Buffer): void {
  const b64 = key.toString("base64");
  // -U: update if exists; -s: service; -a: account; -w: password value
  const r = runSecurity(["add-generic-password", "-U", "-s", SERVICE, "-a", ACCOUNT, "-w", b64]);
  if (r.exitCode !== 0) {
    const err = new TextDecoder().decode(r.stderr).trim();
    throw new Error(`Keychain write failed (${r.exitCode}): ${err || "unknown error"}`);
  }
}

/**
 * Get-or-create the master key. Idempotent across daemon restarts.
 *
 * Test seam: set WHATSAPP_MCP_TEST_KEY=<base64 32 bytes> to skip the
 * Keychain entirely. Tests run in environments where `security` may not
 * be available (CI Linux) and we don't want to hit a real Keychain.
 */
export function getOrCreateMasterKey(): Buffer {
  const testKey = process.env.WHATSAPP_MCP_TEST_KEY;
  if (testKey != null && testKey.length > 0) {
    const buf = Buffer.from(testKey, "base64");
    if (buf.byteLength !== 32) {
      throw new Error(`WHATSAPP_MCP_TEST_KEY must decode to 32 bytes, got ${buf.byteLength}`);
    }
    return buf;
  }

  if (hasKey()) {
    return readKey();
  }
  const fresh = generateKey();
  writeKey(fresh);
  // Read back to confirm round-trip and surface any silent failures early.
  const verify = readKey();
  if (!verify.equals(fresh)) {
    throw new Error("Keychain round-trip mismatch — refusing to start");
  }
  return fresh;
}

/** Delete the master key. Called from the `unlinkAndReset` recovery path
 *  alongside `deleteSession()` so a re-pair generates fresh ciphertext. */
export function deleteMasterKey(): void {
  if (process.env.WHATSAPP_MCP_TEST_KEY != null) return;
  const r = runSecurity(["delete-generic-password", "-s", SERVICE, "-a", ACCOUNT]);
  // Exit 44 = item not found, which is fine.
  if (r.exitCode !== 0 && r.exitCode !== 44) {
    const err = new TextDecoder().decode(r.stderr).trim();
    throw new Error(`Keychain delete failed (${r.exitCode}): ${err}`);
  }
}
