import Foundation

// Mirrors the on-disk JSON written by the imessage-drafts-mcp server's
// stage_draft tool. Keep field names in sync with
// `src/storage/drafts.ts` (TypeScript side).
struct Draft: Codable, Identifiable, Equatable {
  let id: String
  let to_handle: String
  // Contact name resolved from macOS AddressBook at stage time. Null for
  // unknown handles or when AddressBook was unreadable (FDA not granted).
  // Older drafts that predate this field decode as nil automatically via
  // Swift's synthesized Codable init.
  let to_handle_name: String?
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
  // Structured breadcrumb of how the context lookup went. Surfaced in
  // the menu bar's Details disclosure so an empty context_messages is
  // self-explaining ("no chat for this handle", "no handle match", etc.).
  let context_diagnostic: ContextDiagnostic?

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

// Mirrors `ContextLookupDiagnostic` on the TypeScript side. Surfaced when
// `context_messages` is null so the user can tell empty-thread from
// no-handle-match from a real error.
struct ContextDiagnostic: Codable, Hashable {
  let status: String
  let canonical_recipient: String?
  let matched_handle_ids: [Int]
  let chat_id: Int?
  let message_count: Int
  let error: String?

  // Human-readable explanation suitable for showing in the Details disclosure.
  var humanExplanation: String {
    switch status {
    case "ok":
      return "Context lookup ok."
    case "no_input":
      return "Lookup not attempted (no recipient handle and no thread id)."
    case "no_handle_match":
      let canon = canonical_recipient ?? "?"
      return "No matching handle in chat.db for canonical form '\(canon)'. The recipient may never have been part of an iMessage thread, or the canonical form differs."
    case "no_chat_for_handle":
      let n = matched_handle_ids.count
      let canon = canonical_recipient ?? "?"
      return "Found \(n) handle row\(n == 1 ? "" : "s") matching '\(canon)' but no chat contains them. (Self-messages and SMS-only handles sometimes look like this.)"
    case "empty_thread":
      return "Chat \(chat_id.map(String.init) ?? "?") was found but contains zero messages."
    case "error":
      return "Lookup threw: \(error ?? "unknown error")"
    default:
      return "Unknown diagnostic status: \(status)"
    }
  }
}
