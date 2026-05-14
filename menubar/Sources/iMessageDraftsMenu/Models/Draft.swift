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
  // Free-form provenance label set by the staging agent ("Claude Desktop
  // / morning triage", etc.). Older drafts may not have this field —
  // Swift's synthesized init(from:) treats a missing key as nil for
  // Optional properties (in modern Swift), so this is back-compat safe.
  let source: String?
  // Snapshot of the last few messages in the recipient's thread, captured
  // at stage time by the MCP server. Chronological (oldest first). Null
  // for older drafts or when no matching thread was found.
  let context_messages: [ContextMessage]?

  var isSent: Bool { sent_at != nil }

  var stagedDate: Date? { Self.parseISO(staged_at) }
  var sentDate: Date? {
    guard let s = sent_at else { return nil }
    return Self.parseISO(s)
  }

  // Be tolerant of two ISO-8601 shapes we see in the wild:
  //   1. With fractional seconds:    "2026-05-14T21:46:41.064Z"   (what TS .toISOString() produces)
  //   2. Without fractional seconds: "2026-05-14T21:46:41Z"        (older drafts / hand-written test fixtures)
  // ISO8601DateFormatter rejects (2) when configured for (1) and vice
  // versa, so we try both rather than picking one and silently failing
  // half the draft files.
  private static let withFractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()
  private static let withoutFractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
  }()
  private static func parseISO(_ s: String) -> Date? {
    withFractional.date(from: s) ?? withoutFractional.date(from: s)
  }

  static func parseISOPublic(_ s: String) -> Date? {
    parseISO(s)
  }
}

// One message in the recipient's thread, captured at stage time and
// embedded in the draft JSON. Mirrors `DraftContextMessage` on the
// TypeScript side. Identifiable for ForEach — we synthesize a stable id
// from index + sent_at since chat.db's ROWID isn't shipped.
struct ContextMessage: Codable, Hashable {
  let from_me: Bool
  let sender_handle: String?
  let sender_name: String?
  let body: String?
  let sent_at: String?

  var displayName: String {
    if from_me { return "You" }
    return sender_name ?? sender_handle ?? "Unknown"
  }

  var sentDate: Date? {
    guard let s = sent_at else { return nil }
    return Draft.parseISOPublic(s)
  }
}

extension Draft {
  // Stable per-row identity for ForEach over context_messages.
  func contextRowIdentity(at index: Int, message: ContextMessage) -> String {
    "\(id)#\(index)#\(message.sent_at ?? "")"
  }
}
