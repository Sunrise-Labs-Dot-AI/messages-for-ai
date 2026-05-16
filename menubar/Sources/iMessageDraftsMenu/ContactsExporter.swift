import Foundation
import AppKit
import Combine
import os.log

// ContactsExporter is the bridge between the macOS Contacts database
// (via Contacts.app's AppleScript dictionary) and the imessage-mcp
// binary (a Bun process that can't call CoreFoundation APIs directly).
//
// Why AppleScript and not CNContactStore? Empirically tested on macOS
// Sequoia: CNContactStore.requestAccess(for: .contacts) throws "Access
// Denied" synchronously — without ever presenting a consent dialog —
// for any adhoc-signed app, regardless of bundle ID, Info.plist
// contents, Gatekeeper trust state, or tccd cache state. Modern macOS
// reserves CNContactStore consent prompting for apps with a real
// Developer ID signature. That's a non-starter for a local dev tool
// distributed as source.
//
// AppleScript-via-Contacts.app uses the Automation permission family
// (NSAppleEventsUsageDescription) instead of NSContacts. That family
// works fine for adhoc-signed apps — it's the same mechanism used to
// send iMessages via Messages.app, which already works in this app.
// The trade-off is that we get the data through a one-shot enumeration
// rather than a change-observer; refreshes happen when the user opens
// the popover, not in real time. For "who is this number" lookups,
// that's acceptable.
//
// Canonicalization MUST mirror canonHandle in src/chatdb/contacts.ts:
//   - Strings containing '@' → lowercased (emails)
//   - Otherwise → digits-only, last 10 (phone numbers, US-style)

// Our own state enum — separate from CNAuthorizationStatus, which we
// no longer use. Distinguishes "we haven't tried yet" from "automation
// was denied" from "we got the data."
enum ContactsAccessState: Equatable {
  case unknown            // pre-bootstrap, nothing tried yet
  case ok                 // last export succeeded
  case automationDenied   // AppleScript returned errAEEventNotPermitted
  case automationNotDetermined  // AppleScript needs to be tried (first run)
  case failed(String)     // some other error
}

@MainActor
final class ContactsExporter: ObservableObject {
  @Published private(set) var state: ContactsAccessState = .unknown
  @Published private(set) var lastExportAt: Date?
  @Published private(set) var lastExportCount: Int = 0

  private var changeObserver: NSObjectProtocol?
  private let logger = Logger(subsystem: "com.sunriselabs.imessage-drafts", category: "contacts")

  // Schema version must match `CONTACTS_CACHE_SCHEMA_VERSION` in
  // src/storage/contacts-cache.ts. Bumping breaks the read path on
  // older MCP binaries — coordinate the change.
  private let schemaVersion = 1

  init() {
    // Observe Contacts.app's "AB" change notifications. Posted whenever
    // the user edits a contact in Contacts.app — local or iCloud-synced.
    // The notification name is "AddressBookChangedNotification" (yes,
    // the old AddressBook namespace; Contacts.app still posts it).
    changeObserver = DistributedNotificationCenter.default().addObserver(
      forName: NSNotification.Name("AddressBookChangedNotification"),
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.logger.info("AddressBookChangedNotification fired, refreshing sidecar")
      Task { await self?.exportNow() }
    }
  }

  deinit {
    if let obs = changeObserver { DistributedNotificationCenter.default().removeObserver(obs) }
  }

  // Called on first popover open. Idempotent: safe to invoke repeatedly.
  func bootstrap() async {
    await exportNow()
  }

  // User-triggered "try again" from the banner.
  func requestAccessAndExport() async {
    await exportNow()
  }

  // The core export path. Runs the AppleScript synchronously on the
  // main actor (NSAppleScript requires it), parses the output, and
  // writes the sidecar atomically.
  func exportNow() async {
    logger.info("exportNow: running AppleScript against Contacts.app")

    let result = await Task.detached(priority: .userInitiated) { @MainActor in
      Self.runContactsEnumerationScript()
    }.value

    switch result {
    case .success(let lines):
      var handles: [String: String] = [:]
      for line in lines {
        // Each line is "<rawHandle>\t<displayName>"
        guard let tab = line.firstIndex(of: "\t") else { continue }
        let rawHandle = String(line[..<tab])
        let displayName = String(line[line.index(after: tab)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayName.isEmpty else { continue }
        let canon = Self.canonHandle(rawHandle)
        guard !canon.isEmpty else { continue }
        // Last-write-wins. Matches the TS loader's behavior — order is
        // stable per enumeration but not necessarily across runs.
        handles[canon] = displayName
      }
      await writeSidecar(handles: handles, status: "granted")
      state = .ok
      lastExportCount = handles.count
      lastExportAt = Date()
      logger.info("exportNow: exported \(handles.count) handles to sidecar")

    case .automationDenied:
      // User explicitly denied the Automation prompt for Contacts.app.
      // The banner will surface a "re-grant via System Settings" path.
      await writeSidecar(handles: [:], status: "denied")
      state = .automationDenied
      lastExportAt = Date()
      logger.error("exportNow: Automation denied for Contacts.app")

    case .automationNotDetermined:
      // First-run state — the system prompt was shown but the user
      // hasn't responded yet (or our caller raced ahead of the prompt).
      // Don't write a "denied" sidecar; just stay in the not-determined
      // state and let the next exportNow call try again.
      state = .automationNotDetermined
      logger.info("exportNow: Automation prompt presented, awaiting user response")

    case .failed(let msg):
      // Other AppleScript error — Contacts.app missing, etc. Write the
      // sidecar with permission_status: "denied" so the MCP falls back
      // to its SQLite path.
      await writeSidecar(handles: [:], status: "denied")
      state = .failed(msg)
      lastExportAt = Date()
      logger.error("exportNow: AppleScript failed: \(msg, privacy: .public)")
    }
  }

  // MARK: - AppleScript runner

  private enum ScriptResult {
    case success([String])  // each element: "<rawHandle>\t<displayName>"
    case automationDenied
    case automationNotDetermined
    case failed(String)
  }

  private static func runContactsEnumerationScript() -> ScriptResult {
    // The script walks every person in Contacts.app and emits one tab-
    // separated line per handle (phone or email) in the form:
    //   <rawHandle>\t<displayName>\n
    //
    // We do all the formatting in AppleScript rather than returning a
    // structured AEDesc, because the script result string is much
    // easier to parse from Swift (and faster than walking nested lists).
    //
    // try/end-try around each field read tolerates contacts that lack
    // a given field (e.g. company-only entries with no first name).
    let source = """
    tell application "Contacts"
      set tab to (ASCII character 9)
      set lf to (ASCII character 10)
      set output to ""
      repeat with p in people
        try
          set fn to first name of p
        on error
          set fn to ""
        end try
        try
          set ln to last name of p
        on error
          set ln to ""
        end try
        try
          set org to organization of p
        on error
          set org to ""
        end try
        set displayName to (fn & " " & ln)
        if displayName is " " then set displayName to org
        if displayName is "" then set displayName to org

        try
          set phoneList to phones of p
          repeat with ph in phoneList
            try
              set output to output & (value of ph) & tab & displayName & lf
            end try
          end repeat
        end try

        try
          set emailList to emails of p
          repeat with em in emailList
            try
              set output to output & (value of em) & tab & displayName & lf
            end try
          end repeat
        end try
      end repeat
      return output
    end tell
    """

    guard let appleScript = NSAppleScript(source: source) else {
      return .failed("NSAppleScript init returned nil")
    }
    var errorDict: NSDictionary?
    let descriptor = appleScript.executeAndReturnError(&errorDict)

    if let err = errorDict {
      // OSAScript error codes:
      //   -1743: errAEEventNotPermitted — TCC Automation denied
      //   -1744: errAEUserCanceled
      //   -1719: errAEIndexNonNegative (etc — generic)
      let code = (err["NSAppleScriptErrorNumber"] as? Int) ?? 0
      let message = (err["NSAppleScriptErrorMessage"] as? String) ?? "unknown AppleScript error"
      if code == -1743 {
        return .automationDenied
      }
      // -600 procNotFound when Contacts.app isn't installed
      if code == -600 {
        return .failed("Contacts.app not found on this Mac")
      }
      return .failed("AppleScript error \(code): \(message)")
    }

    guard let text = descriptor.stringValue, !text.isEmpty else {
      // Empty result. Could mean "no contacts" or "automation was just
      // granted and the script ran but Contacts.app hadn't indexed
      // anything yet." Treat as success with zero handles — the user
      // can hit Recheck.
      return .success([])
    }

    let lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map(String.init)
    return .success(lines)
  }

  // MARK: - Sidecar I/O

  private static let sidecarDirURL: URL = {
    FileManager.default
      .homeDirectoryForCurrentUser
      .appendingPathComponent(".imessage-mcp", isDirectory: true)
  }()
  private static let sidecarURL: URL = sidecarDirURL.appendingPathComponent("contacts-cache.json")

  private func writeSidecar(handles: [String: String], status: String) async {
    let payload: [String: Any] = [
      "version": schemaVersion,
      "generated_at": ISO8601DateFormatter().string(from: Date()),
      "source": "menubar-applescript-contacts",
      "permission_status": status,
      "count": handles.count,
      "handles": handles,
    ]
    do {
      try FileManager.default.createDirectory(at: Self.sidecarDirURL, withIntermediateDirectories: true)
      let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
      try data.write(to: Self.sidecarURL, options: [.atomic])
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: Self.sidecarURL.path
      )
    } catch {
      logger.error("sidecar write failed: \(error.localizedDescription)")
    }
  }

  // MARK: - Canonicalization (must mirror canonHandle in TS)

  static func canonHandle(_ s: String) -> String {
    if s.contains("@") { return s.lowercased() }
    let digits = s.filter { $0.isNumber }
    if digits.count >= 10 { return String(digits.suffix(10)) }
    return digits
  }

  // MARK: - Deep-link helpers for the permission banner

  static func openAutomationSettings() {
    let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
    if let url = URL(string: urlString) {
      NSWorkspace.shared.open(url)
    }
  }
}
