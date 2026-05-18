import Foundation
import AppKit
import Contacts
import Combine
import os.log

// ContactsExporter is the bridge between the macOS Contacts framework
// (CNContactStore, which sees iCloud-synced contacts + has a real
// native consent prompt) and the imessage-drafts-mcp binary (which is a Bun
// process and can't call CoreFoundation APIs directly).
//
// On launch we:
//   1. Check NSContacts authorization status.
//   2. If undetermined, fire requestAccess(for: .contacts) — this is
//      what pops the "Messages for AI would like to access your
//      Contacts" system dialog.
//   3. On granted, enumerate every CNContact and build a canonical
//      handle → display name map.
//   4. Atomically write it to ~/.messages-mcp/contacts-cache.json.
//   5. Subscribe to CNContactStoreDidChangeNotification + start a
//      10-minute refresh timer so the sidecar tracks edits made in
//      Contacts.app.
//
// The TS side (src/storage/contacts-cache.ts) reads this file as the
// PRIMARY source of contact names and falls back to AddressBook
// SQLite only when the sidecar is missing or empty.
//
// Canonicalization MUST mirror canonHandle in src/chatdb/contacts.ts:
//   - Strings containing '@' → lowercased (emails)
//   - Otherwise → digits-only, last 10 (phone numbers, US-style)
// A divergence here silently breaks contact resolution for affected
// handles. If you change one side, change the other in the same PR.

@MainActor
final class ContactsExporter: ObservableObject {
  @Published private(set) var authorizationStatus: CNAuthorizationStatus = CNContactStore.authorizationStatus(for: .contacts)
  @Published private(set) var lastExportAt: Date?
  @Published private(set) var lastExportCount: Int = 0
  @Published private(set) var lastError: String?

  private let store = CNContactStore()
  private var changeObserver: NSObjectProtocol?
  // Subsystem string follows the Info.plist CFBundleIdentifier. Keep
  // them in lockstep so `log stream --predicate 'subsystem == "..."'`
  // matches the running app.
  private let logger = Logger(subsystem: "com.sunriselabs.messages-for-ai", category: "contacts")

  // Concurrency guards for exportNow.
  //
  // The class is @MainActor, but exportNow() awaits store.enumerateContacts
  // (1-5s on a large AddressBook). During that await the main actor is
  // free, and the .CNContactStoreDidChange observer or a manual refresh
  // tap can call exportNow() again. Two concurrent runs would both
  // JSONSerialization + Data.write(.atomic), with no ordering guarantee
  // on the renames — the loser's snapshot silently lands and could be
  // missing contacts that the winner had picked up.
  //
  // isExporting + pendingExport collapse overlapping calls: the second
  // caller sets pendingExport and returns immediately; whoever holds
  // isExporting re-fires after their defer block runs. Safe because all
  // reads/writes are main-actor-serialized.
  private var isExporting = false
  private var pendingExport = false

  // Schema version must match `CONTACTS_CACHE_SCHEMA_VERSION` in
  // src/storage/contacts-cache.ts. Bumping breaks the read path on
  // older MCP binaries — coordinate the change.
  private let schemaVersion = 1

  init() {
    // Observe live Contacts edits so a contact added/renamed in
    // Contacts.app — or arriving via iCloud sync — refreshes the
    // sidecar within seconds. This notification is documented as
    // reliable for both local mutations and CloudKit-driven changes,
    // so we rely on it as the sole refresh trigger after the
    // app-launch bootstrap. No polling timer.
    changeObserver = NotificationCenter.default.addObserver(
      forName: .CNContactStoreDidChange,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.logger.info("CNContactStoreDidChange fired, refreshing sidecar")
      Task { await self?.exportNow() }
    }
  }

  deinit {
    if let obs = changeObserver { NotificationCenter.default.removeObserver(obs) }
  }

  // Kick off the initial sync at app launch. Safe to call repeatedly —
  // each call refreshes the sidecar atomically.
  //
  // If status is `.notDetermined`, ACTIVELY request access here so the
  // system dialog appears on first popover open. The previous version
  // was too passive — it just wrote an empty sidecar and waited for
  // the user to click the banner button. That left users stuck when
  // status was reported as `.denied` due to TCC caching from a prior
  // build that lacked `NSContactsUsageDescription` (macOS auto-denies
  // when the usage string is missing, and the denial sticks across
  // re-installs until `tccutil reset Contacts com.local.messages-for-ai`).
  func bootstrap() async {
    let initial = CNContactStore.authorizationStatus(for: .contacts)
    authorizationStatus = initial
    logger.info("bootstrap: contacts auth status = \(initial.rawValue) (\(Self.statusDescription(initial), privacy: .public))")

    if initial == .notDetermined {
      // Fire the native consent dialog right now.
      await requestAccessAndExport()
    } else {
      await exportNow()
    }
  }

  // Force a re-prompt or re-export. Called from the
  // ContactsPermissionBanner's "Grant Access" / "Refresh" button and
  // from `bootstrap()` when the initial status is `.notDetermined`.
  //
  // requestAccess only shows the system dialog when status is
  // `.notDetermined`. For `.denied`/`.restricted`, the call is a
  // no-op — the user has to flip the toggle in System Settings (or
  // run `tccutil reset Contacts com.local.messages-for-ai` if the
  // denial was due to an earlier build missing `NSContactsUsageDescription`).
  func requestAccessAndExport() async {
    let current = CNContactStore.authorizationStatus(for: .contacts)
    logger.info("requestAccessAndExport: status before request = \(Self.statusDescription(current), privacy: .public)")
    if current == .notDetermined {
      do {
        let granted = try await store.requestAccess(for: .contacts)
        let after = CNContactStore.authorizationStatus(for: .contacts)
        authorizationStatus = after
        logger.info("requestAccessAndExport: granted=\(granted), status after request = \(Self.statusDescription(after), privacy: .public)")
        if !granted {
          // The user declined the system dialog. Write a sidecar with
          // permission_status: "denied" so the MCP can fall back to
          // SQLite (or surface a clear error) instead of silently
          // reading a stale-or-empty file.
          await writeEmptySidecar(status: "denied")
          return
        }
      } catch {
        lastError = "requestAccess failed: \(error.localizedDescription)"
        logger.error("requestAccess threw: \(error.localizedDescription, privacy: .public)")
        return
      }
    }
    await exportNow()
  }

  // The core export path. Safe to call from the change observer /
  // explicit refresh button. Concurrent calls collapse — the second
  // caller queues a re-run and returns immediately.
  func exportNow() async {
    if isExporting {
      pendingExport = true
      logger.info("exportNow: in-flight; queued re-run")
      return
    }
    isExporting = true
    defer {
      isExporting = false
      // If a CNContactStoreDidChange fired while we were enumerating,
      // catch up now. Use Task so we don't recurse on the same await
      // chain and risk unbounded stack growth under a notification
      // storm.
      if pendingExport {
        pendingExport = false
        Task { await self.exportNow() }
      }
    }

    let status = CNContactStore.authorizationStatus(for: .contacts)
    authorizationStatus = status
    logger.info("exportNow: status=\(Self.statusDescription(status), privacy: .public)")

    let statusString: String
    switch status {
    case .authorized: statusString = "granted"
    case .denied:     statusString = "denied"
    case .restricted: statusString = "restricted"
    case .notDetermined: statusString = "not_determined"
    @unknown default: statusString = "unknown"
    }

    if status != .authorized {
      // macOS 14 added .limitedAccess; treat unknown future cases as
      // "not granted" — they're rare in practice and the user will
      // see the banner asking them to fix it.
      await writeEmptySidecar(status: statusString)
      return
    }

    // Enumerate every contact. Keys are the minimum set we need for
    // the name → handle map.
    let keysToFetch: [CNKeyDescriptor] = [
      CNContactGivenNameKey as CNKeyDescriptor,
      CNContactFamilyNameKey as CNKeyDescriptor,
      CNContactOrganizationNameKey as CNKeyDescriptor,
      CNContactPhoneNumbersKey as CNKeyDescriptor,
      CNContactEmailAddressesKey as CNKeyDescriptor,
    ]
    let request = CNContactFetchRequest(keysToFetch: keysToFetch)
    // Unifying merges contacts that span sources (e.g. an iCloud + a
    // local copy of the same person) — matches what Contacts.app shows.
    request.unifyResults = true

    var handles: [String: String] = [:]

    do {
      try store.enumerateContacts(with: request) { contact, _ in
        let display = Self.displayName(for: contact)
        guard !display.isEmpty else { return }
        for phone in contact.phoneNumbers {
          let canon = Self.canonHandle(phone.value.stringValue)
          if !canon.isEmpty {
            // Last-write-wins. The order CNContactStore enumerates in
            // is stable per fetch but not documented as deterministic
            // across runs; this matches the existing TS loader's
            // last-write-wins behavior.
            handles[canon] = display
          }
        }
        for email in contact.emailAddresses {
          let canon = Self.canonHandle(email.value as String)
          if !canon.isEmpty {
            handles[canon] = display
          }
        }
      }
    } catch {
      lastError = "enumerateContacts failed: \(error.localizedDescription)"
      logger.error("\(error.localizedDescription)")
      return
    }

    let payload: [String: Any] = [
      "version": schemaVersion,
      "generated_at": ISO8601DateFormatter().string(from: Date()),
      "source": "menubar-cnContactStore",
      "permission_status": "granted",
      "count": handles.count,
      "handles": handles,
    ]
    await writeSidecar(payload: payload)
    lastExportAt = Date()
    lastExportCount = handles.count
    lastError = nil
    logger.info("exported \(handles.count) contact handles to sidecar")
  }

  // MARK: - Sidecar I/O

  private static let sidecarDirURL: URL = {
    FileManager.default
      .homeDirectoryForCurrentUser
      .appendingPathComponent(".messages-mcp", isDirectory: true)
  }()
  private static let sidecarURL: URL = sidecarDirURL.appendingPathComponent("contacts-cache.json")

  private func writeSidecar(payload: [String: Any]) async {
    do {
      try FileManager.default.createDirectory(at: Self.sidecarDirURL, withIntermediateDirectories: true)
      let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
      // Atomic write via FoundationKit's options: writes to a temp
      // file in the same directory then renames. Avoids the MCP
      // reading half-written JSON.
      try data.write(to: Self.sidecarURL, options: [.atomic])
      // 0600 — the file contains every contact name + handle on the
      // machine, treat it like the drafts dir.
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: Self.sidecarURL.path
      )
    } catch {
      lastError = "sidecar write failed: \(error.localizedDescription)"
      logger.error("sidecar write failed: \(error.localizedDescription)")
    }
  }

  private func writeEmptySidecar(status: String) async {
    let payload: [String: Any] = [
      "version": schemaVersion,
      "generated_at": ISO8601DateFormatter().string(from: Date()),
      "source": "menubar-cnContactStore",
      "permission_status": status,
      "count": 0,
      "handles": [String: String](),
    ]
    await writeSidecar(payload: payload)
    lastExportCount = 0
    lastExportAt = Date()
  }

  // Human-readable label for `CNAuthorizationStatus`. The framework
  // returns an int from a Swift-side enum but `.rawValue` alone isn't
  // useful in logs. New cases (e.g. `.limited` added in macOS 14) hit
  // the @unknown default and log as "future_<n>".
  private static func statusDescription(_ s: CNAuthorizationStatus) -> String {
    switch s {
    case .notDetermined: return "notDetermined"
    case .restricted:    return "restricted"
    case .denied:        return "denied"
    case .authorized:    return "authorized"
    @unknown default:    return "future_\(s.rawValue)"
    }
  }

  // MARK: - Canonicalization (must mirror canonHandle in TS)

  static func canonHandle(_ s: String) -> String {
    if s.contains("@") { return s.lowercased() }
    let digits = s.filter { $0.isNumber }
    if digits.count >= 10 { return String(digits.suffix(10)) }
    return digits
  }

  private static func displayName(for c: CNContact) -> String {
    let first = c.givenName.trimmingCharacters(in: .whitespacesAndNewlines)
    let last = c.familyName.trimmingCharacters(in: .whitespacesAndNewlines)
    let org = c.organizationName.trimmingCharacters(in: .whitespacesAndNewlines)
    let name = [first, last].filter { !$0.isEmpty }.joined(separator: " ")
    if !name.isEmpty { return name }
    return org
  }

  // MARK: - Deep-link helpers for the permission banner

  static func openContactsSettings() {
    let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts"
    if let url = URL(string: urlString) {
      NSWorkspace.shared.open(url)
    }
  }
}
