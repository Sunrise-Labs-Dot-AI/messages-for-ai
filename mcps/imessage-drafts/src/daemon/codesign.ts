// Shellout wrappers around macOS `codesign` for verifying binaries and
// extracting their (Identifier, TeamIdentifier). Verbatim copy of
// mcps/whatsapp-drafts/src/daemon/codesign.ts — platform-agnostic, no
// transport-specific logic.

const CODESIGN = "/usr/bin/codesign";

interface SpawnResult {
  exitCode: number;
  stdout: string;
  stderr: string;
}

function spawn(args: string[]): SpawnResult {
  const p = Bun.spawnSync({
    cmd: [CODESIGN, ...args],
    stdout: "pipe",
    stderr: "pipe",
  });
  return {
    exitCode: p.exitCode ?? -1,
    stdout: new TextDecoder().decode(p.stdout ?? new Uint8Array()),
    stderr: new TextDecoder().decode(p.stderr ?? new Uint8Array()),
  };
}

export interface VerifyResult {
  valid: boolean;
  requirement: string | null;
  error: string | null;
}

/**
 * Run `codesign --verify --strict --deep` AND extract the designated
 * requirement. Returns a structured result; never throws on signature
 * failure (returns valid:false). Throws only on infra failure.
 */
export function verifyBinary(path: string): VerifyResult {
  const verify = spawn(["--verify", "--strict", "--deep", path]);
  if (verify.exitCode !== 0) {
    return {
      valid: false,
      requirement: null,
      error: verify.stderr.trim() || `codesign --verify exited ${verify.exitCode}`,
    };
  }

  const dr = spawn(["-d", "--requirements", "-", path]);
  if (dr.exitCode !== 0) {
    return { valid: true, requirement: null, error: null };
  }
  const requirement = parseRequirement(dr.stdout + dr.stderr);
  return { valid: true, requirement, error: null };
}

function parseRequirement(out: string): string | null {
  const m = out.match(/designated\s*=>\s*(.+)/);
  if (m == null) return null;
  const text = m[1]!.trim();
  if (text === "(none)") return null;
  return text;
}

export interface BinaryIdentity {
  identifier: string | null;
  teamIdentifier: string | null;
}

/**
 * Extract (Identifier, TeamIdentifier) from a binary's signature via
 * `codesign -dv --verbose=2`. Returns null fields when the binary isn't
 * signed or the line is missing. The daemon authorizes a peer iff BOTH
 * match its own.
 */
export function extractIdentity(path: string): BinaryIdentity {
  const r = spawn(["-dv", "--verbose=2", path]);
  if (r.exitCode !== 0) {
    return { identifier: null, teamIdentifier: null };
  }
  const text = r.stdout + r.stderr;
  const idMatch = text.match(/^Identifier=(.+)$/m);
  const teamMatch = text.match(/^TeamIdentifier=(.+)$/m);
  return {
    identifier: idMatch ? idMatch[1]!.trim() : null,
    teamIdentifier:
      teamMatch && teamMatch[1]!.trim() !== "not set"
        ? teamMatch[1]!.trim()
        : null,
  };
}
