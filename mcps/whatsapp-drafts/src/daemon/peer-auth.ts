// Peer authentication for the Unix-socket JSON-RPC server.
//
// Threat model: ~/.whatsapp-mcp/daemon.sock is reachable by ANY local
// process running as the user (npm postinstall scripts, dev MCP servers,
// browser extensions). Without peer-auth, the 5s minimum-staged-age would
// be the entire send security model and `socat - UNIX-CONNECT:$HOME/...`
// from a malicious local process bypasses every guardrail.
//
// v0.3.0+ production check (runtime self-identity match):
//   1. At daemon startup, extract THIS daemon's codesign Identifier= +
//      TeamIdentifier= and cache them.
//   2. On every peer connect:
//      a. Get peer PID via SO_PEERCRED / LOCAL_PEERPID (FFI getsockopt)
//      b. Resolve PID → binary path via proc_pidpath (FFI libproc)
//      c. Run codesign --verify --strict --deep <path>
//      d. Extract peer's Identifier + TeamIdentifier
//      e. Authorize iff BOTH match the daemon's own
//
// Why self-identity instead of an allowlist:
// the daemon and menubar both ship inside Messages for AI.app, signed
// at build time with `--identifier com.sunriselabs.messages-for-ai`
// (same as the bundle's CFBundleIdentifier so one FDA grant covers
// every inner Mach-O). They inherit the team's signing certificate's
// TeamIdentifier. So "anyone matching me" is exactly the right
// allowlist — no maintenance burden, no risk of forgetting to update
// a baked-in PEER_ALLOWED_REQUIREMENTS string at release time, no
// rebuild-required when a future inner binary joins the bundle.
//
// Why Identifier+Team and not just Identifier:
// an attacker can adhoc-sign a binary with any Identifier they like.
// TeamIdentifier requires Apple's Developer ID signing chain, which
// they can't forge. Requiring both raises the bar from "name match" to
// "name match AND came from our Developer team".
//
// Dev mode (WHATSAPP_MCP_DEV=1): bypasses peer-auth, logs WARNING.
//   - Production safeguard: if THIS daemon's own binary is code-signed
//     AND WHATSAPP_MCP_DEV is set, refuse to start. Guarantees a signed
//     production binary never honors the dev override.

import type { Socket } from "node:net";

import { extractIdentity, verifyBinary } from "./codesign.ts";
import { getPeerPid, pidToPath, socketFd } from "./peer-pid.ts";

const DEV_MODE = process.env.WHATSAPP_MCP_DEV === "1";

/**
 * The daemon's own (Identifier, TeamIdentifier) tuple, derived at
 * startup from `process.argv[0]`. Memoized on first read.
 *
 * Both nulls in development (adhoc signature has no team), which is OK
 * because dev mode short-circuits peer-auth anyway.
 */
let selfIdentityCache: { identifier: string | null; teamIdentifier: string | null } | null = null;

function selfIdentity(): { identifier: string | null; teamIdentifier: string | null } {
  if (selfIdentityCache != null) return selfIdentityCache;
  const ownPath = process.argv[0];
  if (ownPath == null) {
    selfIdentityCache = { identifier: null, teamIdentifier: null };
    return selfIdentityCache;
  }
  selfIdentityCache = extractIdentity(ownPath);
  return selfIdentityCache;
}

/**
 * @internal — test seam. Resets the memoized self-identity so tests
 * can drive {selfIdentity} from a fixture path.
 */
export function _resetSelfIdentityCacheForTesting(): void {
  selfIdentityCache = null;
}

export interface PeerAuthResult {
  authorized: boolean;
  reason?: string;
  identity?: string;
}

export function isDevMode(): boolean {
  return DEV_MODE;
}

/**
 * Returns true iff we're running as a compiled, production-signed daemon
 * binary (not under `bun run` / `node` interpretation).
 *
 * Detection:
 *   1. argv[0]'s basename must NOT be "bun"/"node" — those are
 *      interpreter mode where argv[0] is the runtime, not us.
 *   2. The binary must have a designated requirement under codesign.
 *      Ad-hoc signatures (the default for `bun build --compile` output)
 *      don't get one, so they read as non-production.
 */
function isDaemonSignedForProduction(): boolean {
  // The TEST escape hatch — used by tests to assert the safeguard logic
  // without needing an actual signed binary.
  if (process.env.WHATSAPP_MCP_ASSUME_PRODUCTION === "1") return true;
  if (process.env.WHATSAPP_MCP_ASSUME_PRODUCTION === "0") return false;

  const ownPath = process.argv[0];
  if (ownPath == null) return false;

  // Skip interpreter-mode invocations.
  const basename = ownPath.split("/").pop() ?? "";
  if (basename === "bun" || basename === "node" || basename === "deno") return false;

  try {
    const v = verifyBinary(ownPath);
    // Ad-hoc / dev-only signatures don't have a designated requirement.
    return v.valid && v.requirement != null;
  } catch {
    return false;
  }
}

/**
 * Refuses dev mode in a signed production binary.
 *
 * Returns {allow:true} if startup should proceed; {allow:false, reason}
 * if the daemon must exit. The exit happens at the caller (daemon/index.ts)
 * so this stays a pure predicate for testing.
 */
export function refuseDevModeInProduction(): { allow: boolean; reason?: string } {
  if (!DEV_MODE) return { allow: true };
  if (isDaemonSignedForProduction()) {
    return {
      allow: false,
      reason: "WHATSAPP_MCP_DEV is set but daemon binary is signed for production. Refusing to start.",
    };
  }
  return { allow: true };
}

/**
 * Verify an incoming Unix-socket connection's peer.
 *
 * Dev mode: returns authorized=true and logs a WARNING.
 * Prod mode:
 *   - get peer PID via getsockopt
 *   - resolve PID → binary path via proc_pidpath
 *   - codesign --verify
 *   - peer's (Identifier, TeamIdentifier) must equal the daemon's own
 *   - any failure → authorized=false with explicit reason
 */
export async function authenticatePeer(sock: Socket): Promise<PeerAuthResult> {
  if (DEV_MODE) {
    process.stderr.write("WARNING: dev mode active — peer-auth bypassed\n");
    return { authorized: true, identity: "dev-mode" };
  }

  const fd = socketFd(sock);
  if (fd == null) {
    return {
      authorized: false,
      reason: "could not obtain peer socket fd (Bun internals may have changed; report to maintainers)",
    };
  }
  const pid = getPeerPid(fd);
  if (pid == null) {
    return { authorized: false, reason: "getsockopt(LOCAL_PEERPID) failed" };
  }
  const path = pidToPath(pid);
  if (path == null) {
    return { authorized: false, reason: `proc_pidpath(${pid}) failed` };
  }

  // Step 1: signature must be valid.
  const v = verifyBinary(path);
  if (!v.valid) {
    return {
      authorized: false,
      reason: `peer ${pid} at ${path}: codesign --verify failed: ${v.error ?? "no detail"}`,
    };
  }

  // Step 2: peer's identity must equal the daemon's.
  const mine = selfIdentity();
  if (mine.identifier == null || mine.teamIdentifier == null) {
    return {
      authorized: false,
      reason: "daemon's own identity is missing (Identifier or TeamIdentifier). The daemon must be Developer-ID signed in production.",
    };
  }
  const peer = extractIdentity(path);
  if (peer.identifier !== mine.identifier) {
    return {
      authorized: false,
      reason: `peer Identifier mismatch: got '${peer.identifier ?? "<none>"}', expected '${mine.identifier}'`,
    };
  }
  if (peer.teamIdentifier !== mine.teamIdentifier) {
    return {
      authorized: false,
      reason: `peer TeamIdentifier mismatch: got '${peer.teamIdentifier ?? "<none>"}', expected '${mine.teamIdentifier}'`,
    };
  }
  return {
    authorized: true,
    identity: `pid:${pid} id:${mine.identifier} team:${mine.teamIdentifier}`,
  };
}
