import Foundation

// Mirrors the on-disk JSON written by the imessage-mcp server's
// stage_imessage_draft tool. Keep field names in sync with
// `src/storage/drafts.ts` (TypeScript side).
struct Draft: Codable, Identifiable, Equatable {
  let id: String
  let to_handle: String
  let body: String
  let in_reply_to_thread_id: Int?
  let staged_at: String
  let sent_at: String?
  let send_service: String?

  var isSent: Bool { sent_at != nil }

  var stagedDate: Date? {
    Self.isoFormatter.date(from: staged_at)
  }

  var sentDate: Date? {
    guard let s = sent_at else { return nil }
    return Self.isoFormatter.date(from: s)
  }

  // Drafts on disk include fractional seconds (TS `.toISOString()`).
  private static let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()
}
