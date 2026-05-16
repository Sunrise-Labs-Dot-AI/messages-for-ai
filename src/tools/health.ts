import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { HealthCheckShape } from "../schema.ts";
import { jsonResult, errorResult } from "./_result.ts";
import {
  getAddressBookSqliteDiagnostic,
  getContactsLoadDiagnostic,
  canonHandlePublic,
  resolveHandle,
} from "../chatdb/contacts.ts";
import { getChatDbDiagnostic } from "../chatdb/open.ts";
import { getContactsSidecarDiagnostic } from "../storage/contacts-cache.ts";

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
        const sidecar = getContactsSidecarDiagnostic();
        // SQLite-only diagnostic — `contacts_loaded` reflects strictly
        // the AddressBook SQLite layer, NOT whichever layer happened to
        // serve the data. The function encapsulates its own cache reset
        // (PR 11 review finding #2), so we don't need to clean up after
        // it ourselves.
        const addressbook = getAddressBookSqliteDiagnostic();
        // Layer-of-record diagnostic — answers "where did the contact
        // names actually come from in production load()?". Re-runs
        // load() through the normal sidecar-first path.
        const contacts_load = getContactsLoadDiagnostic();
        const chatdb = getChatDbDiagnostic();

        // FDA matters only for the SQLite fallback. When the sidecar is
        // serving fresh data with granted permission, FDA is irrelevant
        // for contact resolution — but still required for chat.db
        // (thread context lookup). So we keep reporting fda_likely_missing
        // based on chat.db state, and separately note whether contacts
        // were served by the sidecar or fell back to SQLite.
        const contacts_source = contacts_load.source;
        const fda_likely_missing =
          chatdb.open_status === "permission_denied" ||
          (contacts_source !== "sidecar" && addressbook.open_status === "permission_denied");

        const probe = args.probe_handle
          ? {
              input: args.probe_handle,
              canonical: canonHandlePublic(args.probe_handle),
              resolved_name: resolveHandle(args.probe_handle),
            }
          : undefined;

        // Pick the most actionable remediation message based on what's
        // wrong. Order matters: contacts-sidecar-missing is friendlier
        // than FDA-missing, and we should nudge users toward the menu
        // bar app's CNContactStore path before asking them to drag
        // binaries around.
        const instructions = (() => {
          if (sidecar.read_status === "missing") {
            return "Install the menu bar app: `cd menubar && bash scripts/dev-install.sh`, " +
              "then launch /Applications/iMessage Drafts.app and grant Contacts permission " +
              "when prompted. The app writes ~/.imessage-mcp/contacts-cache.json which this " +
              "MCP reads instead of needing Full Disk Access for AddressBook.";
          }
          if (sidecar.permission_status === "denied" || sidecar.permission_status === "restricted") {
            return "The menu bar app is installed but doesn't have Contacts permission. " +
              "Open System Settings → Privacy & Security → Contacts and enable 'iMessage Drafts', " +
              "then click 'Refresh contacts' in the menu bar popover.";
          }
          if (fda_likely_missing) {
            return "Open System Settings → Privacy & Security → Full Disk Access. " +
              "If `binary_path` is already in the list, toggle it OFF then ON " +
              "(macOS sometimes retains a stale grant after a rebuild). If it's " +
              "not in the list, drag the file at `binary_path` into the list. " +
              "Then quit and reopen Claude Desktop so the MCP child process " +
              "re-spawns and picks up the new grant. (FDA is needed for chat.db " +
              "thread-context lookup even when the sidecar handles contact names.)";
          }
          return "Permissions look good. If contact resolution still fails, the " +
            "issue is likely canonicalization — call this tool again with " +
            "`probe_handle` set to the recipient's number to see exactly what " +
            "key the lookup uses.";
        })();

        return jsonResult({
          // `contacts_source` is the back-compat single-value field
          // (string union: sidecar | sidecar_granted_empty |
          // sqlite_fallback | none | test_seam). `contacts_load`
          // provides the structured equivalent — prefer that for new
          // callers. They will always agree on the `.source` value.
          contacts_source,
          contacts_load,
          contacts_sidecar: sidecar,
          // STRICTLY the AddressBook SQLite layer's state. The
          // `contacts_loaded` field here is the SQLite-sourced count
          // and may differ from `contacts_load.count` when the sidecar
          // is winning the resolution race. This separation is the
          // PR 5b fix for code-review finding #7.
          addressbook,
          chatdb,
          fda_likely_missing,
          remediation: {
            settings_url:
              "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
            contacts_settings_url:
              "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts",
            binary_path: process.execPath,
            instructions,
          },
          probe,
        });
      } catch (e) {
        return errorResult(`imessage_mcp_health_check failed: ${(e as Error).message}`);
      }
    }
  );
}
