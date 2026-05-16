// Peer authentication for the Unix-socket JSON-RPC server.
//
// Threat model: ~/.whatsapp-mcp/daemon.sock is reachable by ANY local
// process running as the user (npm postinstall scripts, dev MCP servers,
// browser extensions). Without peer-auth, the 5s minimum-staged-age would
// be the entire send security model and `socat - UNIX-CONNECT:$HOME/...`
// from a malicious local process bypasses every guardrail.
//
// Production check:
//   1. Get peer PID via SO_PEERCRED / LOCAL_PEERPID (FFI getsockopt)
//   2. Resolve PID → binary path via proc_pidpath (FFI libproc)
//   3. Run codesign --verify --strict --deep <path>
//   4. Extract the binary's designated requirement
//   5. Match against PEER_ALLOWED_REQUIREMENTS (exact-string match;
//      wildcards intentionally NOT supported)
//
// Dev mode (WHATSAPP_MCP_DEV=1): bypasses peer-auth, logs WARNING.
//   - Production safeguard: if THIS daemon's own binary is code-signed
//     AND WHATSAPP_MCP_DEV is set, refuse to start. Guarantees a signed
//     production binary never honors the dev override.

import type { Socket } from "node:net";

import { verifyAgainstAllowlist } from "./codesign.ts";
import { getPeerPid, pidToPath, socketFd } from "./peer-pid.ts";

const DEV_MODE = process.env.WHATSAPP_MCP_DEV === "1";

/**
 * Designated requirements of binaries allowed to connect to daemon.sock.
 *
 * Populated at release time with the actual `codesign -d --requirements -`
 * output from the signed `whatsapp-mcp` MCP binary and the signed menu
 * bar app bundle. Empty default → all peers denied in production until
 * configured. This is intentional fail-closed behavior.
 *
 * The release task will:
 *   1. Sign bin/whatsapp-mcp with Developer ID
 *   2. Run `codesign -d --requirements - bin/whatsapp-mcp` and copy the
 *      designated => ... text into PEER_ALLOWED_REQUIREMENTS
 *   3. Do the same for the menu bar app bundle
 *   4. Ship the daemon with those requirements baked in
 */
export const PEER_ALLOWED_REQUIREMENTS: ReadonlyArray<string> = [
  // (empty until signing pipeline lands)
];

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
    const { verifyBinary } = require("./codesign.ts") as typeof import("./codesign.ts");
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
 *   - codesign --verify + designated requirement against allowlist
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

  const r = verifyAgainstAllowlist(path, PEER_ALLOWED_REQUIREMENTS);
  if (!r.ok) {
    return {
      authorized: false,
      reason: `peer ${pid} at ${path}: ${r.reason}`,
    };
  }
  return { authorized: true, identity: `pid:${pid} path:${path}` };
}
