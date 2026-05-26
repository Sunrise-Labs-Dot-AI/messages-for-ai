import Foundation
import Combine

/// Reads draft JSON from BOTH `~/.messages-mcp/drafts/` and
/// `~/.whatsapp-mcp/drafts/` and surfaces them as one merged
/// `@Published` list. Each directory is watched separately via
/// `DispatchSourceFileSystemObject` so new drafts staged by either MCP
/// server appear in the menu bar within ~100 ms.
///
/// The WhatsApp directory is **feature-flagged on its presence**: if
/// `~/.whatsapp-mcp/drafts/` does not exist at app launch, the WhatsApp
/// watcher is never installed and the menubar runs iMessage-only,
/// unchanged from the pre-Phase-3 build. We do NOT create the WhatsApp
/// directory ourselves — that's the WhatsApp MCP daemon's job, and
/// creating it from the menubar would falsely advertise WhatsApp
/// support to other parts of the app on machines where the daemon
/// isn't installed.
@MainActor
final class DraftStore: ObservableObject {
  @Published private(set) var drafts: [Draft] = []
  @Published private(set) var lastRefreshError: String?

  private let imessageDir: URL
  private let whatsappDir: URL
  private let whatsappEnabled: Bool

  private var imessageSource: DispatchSourceFileSystemObject?
  private var imessageHandle: Int32 = -1
  private var whatsappSource: DispatchSourceFileSystemObject?
  private var whatsappHandle: Int32 = -1

  init() {
    let home = FileManager.default.homeDirectoryForCurrentUser
    imessageDir = home.appendingPathComponent(".messages-mcp/drafts")
    whatsappDir = home.appendingPathComponent(".whatsapp-mcp/drafts")
    // Create the iMessage dir if it doesn't exist — this app IS the
    // iMessage menubar surface, so creating it here is fine and matches
    // pre-v0.3.0 behavior. The WhatsApp dir is NOT created here; see
    // class doc comment for rationale.
    try? FileManager.default.createDirectory(at: imessageDir, withIntermediateDirectories: true)
    whatsappEnabled = FileManager.default.fileExists(atPath: whatsappDir.path)
    refresh()
    startWatching()
  }

  deinit {
    imessageSource?.cancel()
    if imessageHandle >= 0 { close(imessageHandle) }
    whatsappSource?.cancel()
    if whatsappHandle >= 0 { close(whatsappHandle) }
  }

  // MARK: - Public API

  func refresh() {
    var errors: [String] = []
    var parsed: [Draft] = []
    parsed.append(contentsOf: loadDir(imessageDir, errors: &errors))
    if whatsappEnabled {
      parsed.append(contentsOf: loadDir(whatsappDir, errors: &errors))
    }
    // Newest staged first; sent drafts trail behind. Both platforms
    // share the same `staged_at` ISO-8601 timestamp shape so the
    // string-comparison sort is total-order-correct across platforms.
    parsed.sort { $0.staged_at > $1.staged_at }
    self.drafts = parsed
    self.lastRefreshError = errors.isEmpty ? nil : errors.joined(separator: "; ")
  }

  /// Marks an **iMessage** draft as sent. WhatsApp drafts are marked
  /// sent by the WhatsApp daemon over the Unix socket — the menubar
  /// never edits WhatsApp draft JSON directly. Calling this with a
  /// WhatsApp draft id is a programmer error and throws.
  func markSent(id: String, sentAt: Date, service: String) throws {
    guard let existing = readDraft(id: id) else {
      throw DraftStoreError.draftNotFound(id)
    }
    guard existing.effectivePlatform == .imessage else {
      // Fail loudly — see method doc.
      throw DraftStoreError.platformMismatch(
        id: id,
        actualPlatform: existing.effectivePlatform,
        operation: "markSent(iMessage-only)"
      )
    }
    guard !existing.isSent else { return } // already sent — be idempotent
    let updated = Draft(
      id: existing.id,
      to_handle: existing.to_handle,
      to_handle_name: existing.to_handle_name,
      body: existing.body,
      in_reply_to_thread_id: existing.in_reply_to_thread_id,
      staged_at: existing.staged_at,
      sent_at: Self.isoString(sentAt),
      send_service: service,
      source: existing.source,
      context_messages: existing.context_messages,
      context_diagnostic: existing.context_diagnostic,
      schema_version: existing.schema_version,
      // Don't write platform back to disk for iMessage drafts —
      // keeps the on-disk JSON shape stable for v0.2.x menubars
      // that might read this file before they're upgraded.
      platform: nil,
      approval_state: existing.approval_state,
      induced_by_unknown_contact: existing.induced_by_unknown_contact,
      // iMessage-only path (guarded above) — these are always nil here,
      // but carry them through so the round-trip stays lossless.
      quoted_message_id: existing.quoted_message_id,
      quoted_preview: existing.quoted_preview
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted]
    let encoded = try encoder.encode(updated)
    try encoded.write(to: draftURL(id: id, platform: existing.effectivePlatform), options: .atomic)
    refresh()
  }

  /// Removes a draft file. Routes by the draft's platform; if no draft
  /// with that id exists in either watched directory, throws.
  func discard(id: String) throws {
    guard let existing = readDraft(id: id) else {
      throw DraftStoreError.draftNotFound(id)
    }
    try FileManager.default.removeItem(at: draftURL(id: id, platform: existing.effectivePlatform))
    refresh()
  }

  // MARK: - Internals

  enum DraftStoreError: Error, CustomStringConvertible {
    case draftNotFound(String)
    case platformMismatch(id: String, actualPlatform: Platform, operation: String)

    var description: String {
      switch self {
      case .draftNotFound(let id):
        return "Draft \(id) not found in either watched directory"
      case .platformMismatch(let id, let p, let op):
        return "Draft \(id) is a \(p.rawValue) draft; cannot perform \(op)"
      }
    }
  }

  /// Resolve the JSON path for a given draft id + platform. Used by
  /// markSent/discard so we never write to the wrong directory.
  private func draftURL(id: String, platform: Platform) -> URL {
    let base: URL
    switch platform {
    case .imessage: base = imessageDir
    case .whatsapp: base = whatsappDir
    }
    return base.appendingPathComponent("\(id).json")
  }

  /// Look up a draft from the in-memory list. Cheaper than re-reading
  /// disk and avoids the race where a watcher fires mid-edit.
  private func readDraft(id: String) -> Draft? {
    drafts.first(where: { $0.id == id })
  }

  /// Read + decode all `*.json` files in a single directory. Errors are
  /// collected (not thrown) so a single broken draft doesn't blank out
  /// the entire list.
  private func loadDir(_ dir: URL, errors: inout [String]) -> [Draft] {
    let urls: [URL]
    do {
      urls = try FileManager.default.contentsOfDirectory(
        at: dir,
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles]
      )
    } catch {
      errors.append("\(dir.lastPathComponent): \(error.localizedDescription)")
      return []
    }
    let decoder = JSONDecoder()
    return urls
      .filter { $0.pathExtension == "json" }
      .compactMap { url in
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(Draft.self, from: data)
      }
  }

  private static func isoString(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: date)
  }

  private func startWatching() {
    imessageSource = watch(dir: imessageDir, handleStore: { [weak self] in self?.imessageHandle = $0 })
    if whatsappEnabled {
      whatsappSource = watch(dir: whatsappDir, handleStore: { [weak self] in self?.whatsappHandle = $0 })
    }
  }

  /// Install a directory watcher. `handleStore` is called on the main
  /// queue with the open fd so the caller can stash it for the cancel
  /// path — avoids reaching into class state from the closure.
  private func watch(
    dir: URL,
    handleStore: @MainActor @escaping (Int32) -> Void
  ) -> DispatchSourceFileSystemObject? {
    let handle = open(dir.path, O_EVTONLY)
    guard handle >= 0 else { return nil }
    handleStore(handle)
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: handle,
      eventMask: [.write, .delete, .extend, .attrib, .rename, .funlock],
      queue: .main
    )
    source.setEventHandler { [weak self] in
      // Coalesce bursts: macOS may fire multiple events for a single
      // write. refresh() is cheap (re-lists ~5 files per dir).
      self?.refresh()
    }
    source.setCancelHandler {
      close(handle)
    }
    source.resume()
    return source
  }
}
