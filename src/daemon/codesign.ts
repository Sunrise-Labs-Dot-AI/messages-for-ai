// Shellout wrappers around macOS `codesign` for verifying binaries and
// extracting their designated requirement.
//
// Used in two places:
//   1. peer-auth.ts asks: "is the daemon's OWN binary signed for
//      production?" — drives refuseDevModeInProduction()
//   2. peer-auth.ts asks: "is THIS peer's binary signed and does its
//      designated requirement match our allowlist?"
//
// macOS `codesign` is preinstalled. Output formats:
//   - `codesign --verify --strict --deep <path>` → exit 0 if signed and
//     valid, non-zero with a message on stderr otherwise.
//   - `codesign -d --requirements - <path>` → prints
//     `designated => <requirement text>` (or `(none)` if no DR).

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
  /** True iff codesign --verify exits 0. */
  valid: boolean;
  /** Designated requirement string (the `=>` payload), if extractable. */
  requirement: string | null;
  /** Stderr message if invalid; null on success. */
  error: string | null;
}

/**
 * Run `codesign --verify --strict --deep` AND extract the designated
 * requirement. Returns a structured result; never throws on signature
 * failure (returns valid:false instead). Throws only on infrastructure
 * failure (codesign not on disk).
 */
export function verifyBinary(path: string): VerifyResult {
  // Step 1: signature verification.
  const verify = spawn(["--verify", "--strict", "--deep", path]);
  if (verify.exitCode !== 0) {
    return {
      valid: false,
      requirement: null,
      error: verify.stderr.trim() || `codesign --verify exited ${verify.exitCode}`,
    };
  }

  // Step 2: extract designated requirement. stdout is empty on success;
  // the requirement text lands on stderr in the form
  //   `designated => identifier "x" and anchor apple generic and ...`
  // — but with `--requirements -` flag the requirement is printed to
  // stdout. The exit code distinguishes "no requirement" (still 0) from
  // codesign infra error (non-zero).
  const dr = spawn(["-d", "--requirements", "-", path]);
  if (dr.exitCode !== 0) {
    return {
      valid: true,
      requirement: null,
      error: null,
    };
  }
  const requirement = parseRequirement(dr.stdout + dr.stderr);
  return { valid: true, requirement, error: null };
}

function parseRequirement(out: string): string | null {
  // codesign emits a line like:
  //   designated => identifier "com.foo" and anchor apple generic and ...
  // OR
  //   designated => (none)
  const m = out.match(/designated\s*=>\s*(.+)/);
  if (m == null) return null;
  const text = m[1]!.trim();
  if (text === "(none)") return null;
  return text;
}

/**
 * Verify and check the requirement matches an allowlist.
 *
 * The allowlist is exact-string-match on the requirement. Wildcards
 * are intentionally NOT supported (defense against bypass via lenient
 * matching).
 */
export function verifyAgainstAllowlist(path: string, allowedRequirements: ReadonlyArray<string>): {
  ok: boolean;
  reason: string;
} {
  const v = verifyBinary(path);
  if (!v.valid) {
    return { ok: false, reason: `codesign --verify failed: ${v.error ?? "no detail"}` };
  }
  if (v.requirement == null) {
    return { ok: false, reason: "binary is signed but has no designated requirement" };
  }
  if (!allowedRequirements.includes(v.requirement)) {
    return { ok: false, reason: `requirement not in allowlist: ${v.requirement}` };
  }
  return { ok: true, reason: "matched allowlist" };
}
