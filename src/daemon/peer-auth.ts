// Peer authentication for the Unix-socket JSON-RPC server.
//
// Threat model: ~/.whatsapp-mcp/daemon.sock is reachable by ANY local
// process running as the user (npm postinstall scripts, dev MCP servers,
// browser extensions). Without peer-auth, the 5s minimum-staged-age would
// be the entire send security model and `socat - UNIX-CONNECT:$HOME/...`
// from a malicious local process bypasses every guardrail.
//
// Production check (TODO — wires SecCodeCheckValidity):
//   1. Get peer PID via SO_PEERCRED / LOCAL_PEERPID
//   2. Resolve the peer's code-signing identity:
//        SecCodeCopyGuestWithAttributes + SecCodeCheckValidity
//   3. Match against designated requirements for:
//        a) menu bar app bundle id (ai.sunriselabs.imessage-drafts)
//        b) whatsapp-mcp signed stdio binary
//
// Dev mode (WHATSAPP_MCP_DEV=1): bypasses peer-auth, logs WARNING.
//   - Production safeguard: a SIGNED daemon binary refuses to honor the
//     dev override at startup. The launchd plist MUST NOT set this var;
//     a CI check in Phase 4 validates the shipped plist contains no such
//     env entry.
//
// NOTE: this scaffold implements the dev-mode bypass and the production
// safeguard. The actual SecCode* check is stubbed — it requires bridging
// to the macOS Security framework via FFI or a small Swift helper. Real
// implementation lands before v0.1.0 release.

import { Socket } from "node:net";

const DEV_MODE = process.env.WHATSAPP_MCP_DEV === "1";

export interface PeerAuthResult {
  authorized: boolean;
  reason?: string;
  identity?: string;
}

export function isDevMode(): boolean {
  return DEV_MODE;
}

/**
 * Refuses dev mode in a signed production binary.
 *
 * Returns true if startup should proceed; false if the daemon must exit.
 * The exit happens at the caller (daemon/index.ts) so this stays a pure
 * predicate for testing.
 *
 * TODO: implement isProductionBinary() via Bun.spawn("codesign", [...])
 * checking the daemon's own binary path. For now, an env-var escape
 * (`WHATSAPP_MCP_ASSUME_PRODUCTION=1`) simulates the prod state in tests.
 */
export function refuseDevModeInProduction(): { allow: boolean; reason?: string } {
  if (!DEV_MODE) return { allow: true };
  const looksLikeProduction = process.env.WHATSAPP_MCP_ASSUME_PRODUCTION === "1";
  if (looksLikeProduction) {
    return {
      allow: false,
      reason: "WHATSAPP_MCP_DEV is set but binary is signed for production. Refusing to start.",
    };
  }
  return { allow: true };
}

/**
 * Verify an incoming Unix-socket connection's peer.
 *
 * In dev mode: returns authorized=true and logs a WARNING.
 * In prod mode: TODO — runs the SecCodeCheckValidity dance.
 */
export async function authenticatePeer(_sock: Socket): Promise<PeerAuthResult> {
  if (DEV_MODE) {
    process.stderr.write("WARNING: dev mode active — peer-auth bypassed\n");
    return { authorized: true, identity: "dev-mode" };
  }
  // TODO(security): implement SO_PEERCRED + SecCodeCheckValidity.
  // For now, default-deny in production until the real check lands.
  return {
    authorized: false,
    reason: "Peer authentication not yet implemented. Run with WHATSAPP_MCP_DEV=1 to bypass.",
  };
}
