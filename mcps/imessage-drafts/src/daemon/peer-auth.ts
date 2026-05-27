// Peer authentication for the iMessage daemon's Unix-socket JSON-RPC server.
// Adapted from mcps/whatsapp-drafts/src/daemon/peer-auth.ts (only the dev
// env-var names + transport strings differ; the self-identity logic is
// identical).
//
// Threat model: ~/.messages-mcp/daemon.sock is reachable by ANY local
// process running as the user. Without peer-auth, any local process could
// `socat - UNIX-CONNECT:$HOME/.messages-mcp/daemon.sock` and read the user's
// entire message history through the daemon's chat.db access.
//
// Production check (runtime self-identity match):
//   1. At startup, cache THIS daemon's codesign Identifier + TeamIdentifier.
//   2. On every peer connect: get peer PID (LOCAL_PEERPID) → resolve to
//      binary path (proc_pidpath) → codesign --verify → extract peer's
//      Identifier + TeamIdentifier → authorize iff BOTH match the daemon's.
//
// Why self-identity instead of an allowlist: the daemon and the MCP both
// ship inside Messages for AI.app, signed with `--identifier
// com.sunriselabs.messages-for-ai` and the same Developer Team. So "anyone
// matching me" is exactly the right allowlist — zero maintenance.
//
// Why Identifier+Team and not just Identifier: an attacker can adhoc-sign a
// binary with any Identifier; TeamIdentifier requires Apple's Developer ID
// chain, which they can't forge.
//
// Dev mode (MESSAGES_MCP_DEV=1): bypasses peer-auth, logs WARNING. A signed
// production daemon refuses to honor the override (refuseDevModeInProduction).

import type { Socket } from "node:net";

import { extractIdentity, verifyBinary } from "./codesign.ts";
import { getPeerPid, pidToPath, socketFd } from "./peer-pid.ts";

const DEV_MODE = process.env.MESSAGES_MCP_DEV === "1";

let selfIdentityCache: { identifier: string | null; teamIdentifier: string | null } | null = null;

function selfIdentity(): { identifier: string | null; teamIdentifier: string | null } {
  if (selfIdentityCache != null) return selfIdentityCache;
  // process.execPath (not argv[0]): under `bun build --compile` argv[0] is
  // the literal "bun", but execPath is the running binary's absolute path.
  const ownPath = process.execPath;
  if (ownPath == null || ownPath === "") {
    selfIdentityCache = { identifier: null, teamIdentifier: null };
    return selfIdentityCache;
  }
  selfIdentityCache = extractIdentity(ownPath);
  return selfIdentityCache;
}

/** @internal test seam — reset the memoized self-identity. */
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

function isDaemonSignedForProduction(): boolean {
  if (process.env.MESSAGES_MCP_ASSUME_PRODUCTION === "1") return true;
  if (process.env.MESSAGES_MCP_ASSUME_PRODUCTION === "0") return false;

  const ownPath = process.execPath;
  if (ownPath == null || ownPath === "") return false;

  const basename = ownPath.split("/").pop() ?? "";
  if (basename === "bun" || basename === "node" || basename === "deno") return false;

  try {
    const v = verifyBinary(ownPath);
    return v.valid && v.requirement != null;
  } catch {
    return false;
  }
}

/**
 * Refuses dev mode in a signed production binary. Returns {allow:true} if
 * startup should proceed; {allow:false, reason} if the daemon must exit.
 */
export function refuseDevModeInProduction(): { allow: boolean; reason?: string } {
  if (!DEV_MODE) return { allow: true };
  if (isDaemonSignedForProduction()) {
    return {
      allow: false,
      reason: "MESSAGES_MCP_DEV is set but daemon binary is signed for production. Refusing to start.",
    };
  }
  return { allow: true };
}

/**
 * Verify an incoming Unix-socket connection's peer. Dev mode short-circuits
 * to authorized=true with a WARNING.
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

  const v = verifyBinary(path);
  if (!v.valid) {
    return {
      authorized: false,
      reason: `peer ${pid} at ${path}: codesign --verify failed: ${v.error ?? "no detail"}`,
    };
  }

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
