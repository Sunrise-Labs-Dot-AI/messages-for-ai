import Foundation
import Combine

// Reads ~/.imessage-mcp/drafts and surfaces them as an @Published list.
// Watches the directory via DispatchSourceFileSystemObject so new drafts
// staged by the MCP server appear in the menu bar within ~100ms.
@MainActor
final class DraftStore: ObservableObject {
  @Published private(set) var drafts: [Draft] = []
  @Published private(set) var lastRefreshError: String?

  private let dir: URL
  private var fileSource: DispatchSourceFileSystemObject?
  private var dirHandle: Int32 = -1

  init() {
    let home = FileManager.default.homeDirectoryForCurrentUser
    dir = home.appendingPathComponent(".imessage-mcp/drafts")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    refresh()
    startWatching()
  }

  deinit {
    fileSource?.cancel()
    if dirHandle >= 0 { close(dirHandle) }
  }

  // MARK: - Public API

  func refresh() {
    do {
      let urls = try FileManager.default.contentsOfDirectory(
        at: dir,
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles]
      )
      let decoder = JSONDecoder()
      let parsed: [Draft] = urls
        .filter { $0.pathExtension == "json" }
        .compactMap { url in
          guard let data = try? Data(contentsOf: url) else { return nil }
          return try? decoder.decode(Draft.self, from: data)
        }
        // Newest staged first; sent drafts trail behind.
        .sorted { ($0.staged_at) > ($1.staged_at) }
      self.drafts = parsed
      self.lastRefreshError = nil
    } catch {
      self.lastRefreshError = error.localizedDescription
    }
  }

  func markSent(id: String, sentAt: Date, service: String) throws {
    let url = draftURL(id)
    let data = try Data(contentsOf: url)
    let existing = try JSONDecoder().decode(Draft.self, from: data)
    guard !existing.isSent else { return } // already sent — be idempotent
    let updated = Draft(
      id: existing.id,
      to_handle: existing.to_handle,
      body: existing.body,
      in_reply_to_thread_id: existing.in_reply_to_thread_id,
      staged_at: existing.staged_at,
      sent_at: Self.isoString(sentAt),
      send_service: service,
      to_handle_name: existing.to_handle_name,
      source: existing.source,
      context_messages: existing.context_messages,
      context_diagnostic: existing.context_diagnostic
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted]
    let encoded = try encoder.encode(updated)
    try encoded.write(to: url, options: .atomic)
    refresh()
  }

  func discard(id: String) throws {
    try FileManager.default.removeItem(at: draftURL(id))
    refresh()
  }

  // MARK: - Internals

  private func draftURL(_ id: String) -> URL {
    dir.appendingPathComponent("\(id).json")
  }

  private static func isoString(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: date)
  }

  private func startWatching() {
    let handle = open(dir.path, O_EVTONLY)
    guard handle >= 0 else { return }
    dirHandle = handle
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: handle,
      eventMask: [.write, .delete, .extend, .attrib, .rename, .funlock],
      queue: .main
    )
    source.setEventHandler { [weak self] in
      // Coalesce bursts: macOS may fire multiple events for a single write.
      // refresh() is cheap, just re-list a directory of ~5 files.
      self?.refresh()
    }
    source.setCancelHandler { [weak self] in
      if let h = self?.dirHandle, h >= 0 {
        close(h)
        self?.dirHandle = -1
      }
    }
    source.resume()
    fileSource = source
  }
}
