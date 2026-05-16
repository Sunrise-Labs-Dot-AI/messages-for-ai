import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { HealthCheckShape } from "../schema.ts";
import { jsonResult, errorResult } from "./_result.ts";
import {
  getAddressBookDiagnostic,
  canonHandlePublic,
  resolveHandle,
} from "../chatdb/contacts.ts";
import { getChatDbDiagnostic } from "../chatdb/open.ts";

// `imessage_mcp_health_check` exists to break a specific debugging
// deadlock: when `to_handle_name` keeps coming back null for a known
// contact, the user can't tell whether FDA is missing on the binary,
// whether the AddressBook DB opened but is empty, whether the contact
// is genuinely absent, or whether the phone-number canonicalization
// mismatched. This tool answers all four in one call.
//
// It's intentionally NOT marked destructive / open-world — it's a
// read-only inspection of the MCP server's own permission state.
//
// The `remediation.binary_path` field is `process.execPath`, which on
// the compiled bun output is the path to `imessage-mcp` itself — i.e.
// the exact file the user needs to add to System Settings → Privacy &
// Security → Full Disk Access.
export function registerHealthTools(server: McpServer): void {
  server.registerTool(
    "imessage_mcp_health_check",
    {
      title: "Diagnose imessage-mcp permissions and contact lookup",
      description:
        "Returns the live state of AddressBook and chat.db access (Full Disk Access " +
        "is required for both). Pass `probe_handle` to also report how a phone/email " +
        "canonicalizes and whether it resolves to a contact name. Use this when " +
        "`to_handle_name` keeps coming back null for a known contact, when Send/list " +
        "tools error with permission-denied messages, or to confirm a fresh FDA grant " +
        "actually took effect after a binary rebuild.",
      inputSchema: HealthCheckShape,
    },
    async (args) => {
      try {
        const addressbook = getAddressBookDiagnostic();
        const chatdb = getChatDbDiagnostic();
        const fda_likely_missing =
          addressbook.open_status === "permission_denied" ||
          chatdb.open_status === "permission_denied";

        const probe = args.probe_handle
          ? {
              input: args.probe_handle,
              canonical: canonHandlePublic(args.probe_handle),
              resolved_name: resolveHandle(args.probe_handle),
            }
          : undefined;

        return jsonResult({
          addressbook,
          chatdb,
          fda_likely_missing,
          remediation: {
            settings_url:
              "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
            binary_path: process.execPath,
            instructions: fda_likely_missing
              ? "Open System Settings → Privacy & Security → Full Disk Access. " +
                "If `binary_path` is already in the list, toggle it OFF then ON " +
                "(macOS sometimes retains a stale grant after a rebuild). If it's " +
                "not in the list, drag the file at `binary_path` into the list. " +
                "Then quit and reopen Claude Desktop so the MCP child process " +
                "re-spawns and picks up the new grant."
              : "Permissions look good. If contact resolution still fails, the " +
                "issue is likely canonicalization — call this tool again with " +
                "`probe_handle` set to the recipient's number to see exactly what " +
                "key the lookup uses.",
          },
          probe,
        });
      } catch (e) {
        return errorResult(`imessage_mcp_health_check failed: ${(e as Error).message}`);
      }
    }
  );
}
