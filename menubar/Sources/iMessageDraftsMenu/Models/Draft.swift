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
}
