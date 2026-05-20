import Foundation

/// Which transport this draft targets. Read from the draft JSON's
/// `platform` field; defaults to `.imessage` when the field is absent
/// (back-compat with pre-v0.3.0 drafts in `~/.messages-mcp/drafts/`).
///
/// Encoded as a lowercase string in JSON (`"imessage"` / `"whatsapp"`)
/// to match the TypeScript side's serialization.
enum Platform: String, Codable, Equatable, CaseIterable {
  case imessage
  case whatsapp
}

/// Whether a WhatsApp draft has been approved for send by the user in
/// the menubar. iMessage drafts don't carry this field on disk — the
/// approval signal is conveyed entirely by the hold-to-fire UX. For
/// WhatsApp the daemon refuses send until `approval_state == "approved"`.
enum ApprovalState: String, Codable, Equatable {
  case pending
  case approved
}

// Mirrors the on-disk JSON written by either MCP server's stage_draft
// tool:
//   - iMessage: `~/.messages-mcp/drafts/{uuid}.json`,
//     TS source `src/storage/drafts.ts` in messages-for-ai repo
//   - WhatsApp: `~/.whatsapp-mcp/drafts/{uuid}.json`,
//     TS source `src/storage/drafts.ts` in whatsapp-mcp repo
//
// Fields present only on one platform are Optional; Swift's synthesized
// `init(from:)` treats absent JSON keys as nil for Optional properties,
// so the same struct decodes both shapes without conditional logic.
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

  // ── WhatsApp-specific fields (Optional for iMessage drafts) ──────────
  /// Written by the WhatsApp MCP's `stage_draft`. Currently always `1`.
  /// Reserved so the menubar can refuse drafts written by a future
  /// daemon version it doesn't understand (forward-compat).
  let schema_version: Int?
  /// Raw transport tag from the JSON `platform` field. Optional because
  /// iMessage drafts predate the field. Callers should usually go
  /// through `effectivePlatform` instead — it returns a non-Optional
  /// `Platform` with `.imessage` as the default for legacy drafts.
  let platform: Platform?
  /// Whether the user has tapped "approve" on the WhatsApp draft in the
  /// menubar. iMessage drafts don't write this field; for those, the
  /// effective state is conveyed by the hold-to-fire interaction itself.
  let approval_state: ApprovalState?
  /// True when the WhatsApp daemon staged this draft within 60 s of an
  /// inbound message from a non-contact sender. The menubar uses this
  /// to raise the hold-to-fire duration from 1 s to 2 s — a safety
  /// nudge against prompt-injection-driven drafts induced by an
  /// unknown sender. Absent / false on iMessage drafts.
  let induced_by_unknown_contact: Bool?

  /// Effective transport. Returns the stored `platform` if present, or
  /// `.imessage` as the back-compat default for legacy drafts that
  /// predate the field. Always non-nil — call sites can `switch` on
  /// this without an Optional dance.
  var effectivePlatform: Platform { platform ?? .imessage }

  var isSent: Bool { sent_at != nil }

  /// The WhatsApp daemon writes `approval_state: "approved"` on the
  /// draft JSON when the user confirms in the menubar. iMessage drafts
  /// never write this field. This computed flag answers "should the
  /// menubar present this as ready-to-fire?" uniformly across both
  /// platforms.
  var isApproved: Bool { approval_state == .approved }

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
//
// Dual-key decoding: v0.3.0/v0.3.1 WhatsApp daemons wrote `sender_jid`
// (a JID) + `ts` (unix-ms number) instead of `sender_handle` + `sent_at`
// (the names the iMessage path has always used and the menubar's Codable
// expects). v0.3.2 daemons emit the new names; the decoder below accepts
// either shape so in-flight drafts staged on the old daemon still render
// context correctly after upgrade.
//
// REMOVE after v0.3.3 ships — by then any in-flight v0.3.0/v0.3.1 WhatsApp
// drafts will have been swept by sweepDrafts() (24h sent / 7-day TTL).
// Tracked: v0.3.3 plan item "delete dual-key compat in ContextMessage."
struct ContextMessage: Codable, Hashable {
  let from_me: Bool
  let sender_handle: String?
  let sender_name: String?
  let body: String?
  let sent_at: String?

  enum CodingKeys: String, CodingKey {
    case from_me
    case sender_handle
    case sender_name
    case body
    case sent_at
    // Legacy v0.3.0/v0.3.1 WhatsApp keys — accept but never emit.
    case sender_jid
    case ts
  }

  init(from_me: Bool, sender_handle: String?, sender_name: String?, body: String?, sent_at: String?) {
    self.from_me = from_me
    self.sender_handle = sender_handle
    self.sender_name = sender_name
    self.body = body
    self.sent_at = sent_at
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.from_me = try c.decode(Bool.self, forKey: .from_me)
    // Prefer the new key; fall back to the legacy one if the new one
    // is absent. Both keys present (shouldn't happen) → new wins.
    self.sender_handle = try (c.decodeIfPresent(String.self, forKey: .sender_handle)
      ?? c.decodeIfPresent(String.self, forKey: .sender_jid))
    self.sender_name = try c.decodeIfPresent(String.self, forKey: .sender_name)
    self.body = try c.decodeIfPresent(String.self, forKey: .body)
    if let isoString = try c.decodeIfPresent(String.self, forKey: .sent_at) {
      self.sent_at = isoString
    } else if let unixMs = try c.decodeIfPresent(Double.self, forKey: .ts) {
      // Legacy daemons wrote ts as unix-ms number; convert to the ISO
      // string the menubar expects. The conversion is one-way — encode
      // below always emits sent_at.
      let f = ISO8601DateFormatter()
      f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      self.sent_at = f.string(from: Date(timeIntervalSince1970: unixMs / 1000))
    } else {
      self.sent_at = nil
    }
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(from_me, forKey: .from_me)
    try c.encodeIfPresent(sender_handle, forKey: .sender_handle)
    try c.encodeIfPresent(sender_name, forKey: .sender_name)
    try c.encodeIfPresent(body, forKey: .body)
    try c.encodeIfPresent(sent_at, forKey: .sent_at)
  }

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
