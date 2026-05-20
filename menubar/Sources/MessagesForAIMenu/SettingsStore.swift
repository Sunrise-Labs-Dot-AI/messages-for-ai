import Foundation
import Combine

// Reads + writes ~/.messages-mcp/settings.json. The iMessage MCP server
// reads the same file on every send_draft call (no caching), so toggling
// here takes effect immediately for the next send attempt.
//
// v0.3.0 introduced schema v2: nested transports.{imessage,whatsapp} +
// first_run_complete sentinel. The legacy flat `require_approval` key is
// mirrored at the root so v0.2.x MCP server processes still in flight
// (Claude Desktop hasn't been restarted yet) keep seeing the right value.
@MainActor
final class SettingsStore: ObservableObject {
  @Published var requireApproval: Bool {
    didSet { persist() }
  }
  @Published var firstRunComplete: Bool {
    didSet { persist() }
  }
  @Published var imessageEnabled: Bool {
    didSet { persist() }
  }
  @Published var whatsappEnabled: Bool {
    didSet { persist() }
  }
  /// WhatsApp's own require_approval. Persisted to ~/.messages-mcp/
  /// settings.json under transports.whatsapp.require_approval AND
  /// mirrored into ~/.whatsapp-mcp/settings.json so the WhatsApp MCP +
  /// daemon (which read from THAT file on every send) see the toggle
  /// immediately. We only touch the one field on the daemon's file,
  /// preserving rate limits / TTLs / other knobs that live there.
  @Published var whatsappRequireApproval: Bool {
    didSet {
      persist()
      mirrorIntoWhatsAppMcpSettings()
    }
  }
  /// True once the user has confirmed Claude can see this app's MCPs via
  /// the setup walkthrough. Existing v0.3.0/v0.3.1 users see the
  /// walkthrough once after upgrade (the discoverability bug PR #14 fixed
  /// made the upgrade-time confirmation valuable); absence in the on-disk
  /// file defaults to false. Set by SetupWalkthroughView's "All set"
  /// button.
  @Published var walkthroughComplete: Bool {
    didSet { persist() }
  }
  /// True once the user has explicitly skipped the walkthrough. Suppresses
  /// the auto-open on launch but Settings → Status still surfaces unverified
  /// state. Set by SetupWalkthroughView's "Skip for now" button.
  @Published var walkthroughSkipped: Bool {
    didSet { persist() }
  }

  @Published private(set) var lastError: String?

  private let file: URL
  private let whatsappMcpFile: URL

  init() {
    let dir = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".messages-mcp")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    self.file = dir.appendingPathComponent("settings.json")
    self.whatsappMcpFile = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".whatsapp-mcp")
      .appendingPathComponent("settings.json")

    let loaded = Self.load(from: file, whatsappMcp: whatsappMcpFile)
    self.requireApproval = loaded.requireApproval
    self.firstRunComplete = loaded.firstRunComplete
    self.imessageEnabled = loaded.imessageEnabled
    self.whatsappEnabled = loaded.whatsappEnabled
    self.whatsappRequireApproval = loaded.whatsappRequireApproval
    self.walkthroughComplete = loaded.walkthroughComplete
    self.walkthroughSkipped = loaded.walkthroughSkipped

    if loaded.requiresMigrationWrite {
      // First run, or v1→v2 migration: write the canonical v2 schema
      // back to disk so the MCP server has a file to read and so we
      // don't repeat the migration on every launch.
      persistInit()
    }
  }

  // MARK: - Load + migrate

  fileprivate struct LoadedState {
    let requireApproval: Bool
    let firstRunComplete: Bool
    let imessageEnabled: Bool
    let whatsappEnabled: Bool
    let whatsappRequireApproval: Bool
    let walkthroughComplete: Bool
    let walkthroughSkipped: Bool
    /// True when the on-disk file is missing or was v1; tells init() to
    /// write the canonical v2 schema immediately.
    let requiresMigrationWrite: Bool
  }

  private static func load(from file: URL, whatsappMcp: URL) -> LoadedState {
    // WhatsApp's own settings.json is the source of truth for the
    // daemon's behavior. If our menubar copy and the daemon's disagree,
    // trust the daemon's — it's what the send path actually checks.
    let whatsappMcpApproval = loadWhatsAppMcpApproval(from: whatsappMcp)

    guard FileManager.default.fileExists(atPath: file.path),
          let data = try? Data(contentsOf: file),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      // Fresh install: defaults, will write canonical schema on init.
      return LoadedState(
        requireApproval: true,
        firstRunComplete: false,
        imessageEnabled: true,
        whatsappEnabled: false,
        whatsappRequireApproval: whatsappMcpApproval ?? true,
        walkthroughComplete: false,
        walkthroughSkipped: false,
        requiresMigrationWrite: true
      )
    }

    let schemaVersion = json["schema_version"] as? Int ?? 1

    if schemaVersion >= 2 {
      // v2 reader. Tolerate missing fields with safe defaults.
      let transports = json["transports"] as? [String: Any] ?? [:]
      let imessage = transports["imessage"] as? [String: Any] ?? [:]
      let whatsapp = transports["whatsapp"] as? [String: Any] ?? [:]
      // Prefer the daemon's view if present; otherwise fall back to
      // the menubar's mirror; otherwise default-on.
      let whatsappApproval = whatsappMcpApproval
        ?? (whatsapp["require_approval"] as? Bool)
        ?? true
      return LoadedState(
        requireApproval: imessage["require_approval"] as? Bool ?? true,
        firstRunComplete: json["first_run_complete"] as? Bool ?? false,
        imessageEnabled: imessage["enabled"] as? Bool ?? true,
        whatsappEnabled: whatsapp["enabled"] as? Bool ?? false,
        whatsappRequireApproval: whatsappApproval,
        // Absence == false. Existing v0.3.0/v0.3.1 users get the
        // walkthrough on upgrade — exactly the cohort hit by the
        // discoverability bug PR #14 fixed. Per the resolved Open
        // Question #1 in the v0.3.2 plan.
        walkthroughComplete: json["walkthrough_complete"] as? Bool ?? false,
        walkthroughSkipped: json["walkthrough_skipped"] as? Bool ?? false,
        requiresMigrationWrite: false
      )
    }

    // v1 → v2 migration. The user has been running v0.1.x or v0.2.x,
    // so first_run_complete should be true (they've already used the
    // app). iMessage is enabled by definition (it was the only transport).
    // WhatsApp defaults to off — the user opts in via the Settings UI.
    return LoadedState(
      requireApproval: json["require_approval"] as? Bool ?? true,
      firstRunComplete: true,
      imessageEnabled: true,
      whatsappEnabled: false,
      whatsappRequireApproval: whatsappMcpApproval ?? true,
      walkthroughComplete: false,
      walkthroughSkipped: false,
      requiresMigrationWrite: true
    )
  }

  /// Read just the `require_approval` field from ~/.whatsapp-mcp/
  /// settings.json. Returns nil if the file doesn't exist or the
  /// field is missing — caller decides the default.
  private static func loadWhatsAppMcpApproval(from file: URL) -> Bool? {
    guard FileManager.default.fileExists(atPath: file.path),
          let data = try? Data(contentsOf: file),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return json["require_approval"] as? Bool
  }

  // MARK: - Write

  private func persistInit() {
    // Same as persist() but doesn't go through didSet (which would fire
    // during init before self is fully constructed).
    write()
  }

  private func persist() {
    write()
  }

  private func write() {
    do {
      let data = try JSONSerialization.data(
        withJSONObject: currentDocument(),
        options: [.prettyPrinted, .sortedKeys]
      )
      try data.write(to: file, options: .atomic)
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
      lastError = nil
    } catch {
      lastError = "couldn't write settings.json: \(error.localizedDescription)"
    }
  }

  private func currentDocument() -> [String: Any] {
    [
      "schema_version": 2,
      "first_run_complete": firstRunComplete,
      // Additive fields for v0.3.2; absence defaults to false on read so
      // upgrading users see the walkthrough once. Not bumping schema_version
      // because the additive shape is back-compat for v0.3.x readers.
      "walkthrough_complete": walkthroughComplete,
      "walkthrough_skipped": walkthroughSkipped,
      // Legacy flat key, mirrored from transports.imessage.require_approval.
      // Lets v0.2.x MCP server processes still running in this Claude
      // Desktop session keep seeing the toggle until next restart.
      "require_approval": requireApproval,
      "transports": [
        "imessage": [
          "enabled": imessageEnabled,
          "require_approval": requireApproval
        ],
        "whatsapp": [
          "enabled": whatsappEnabled,
          "require_approval": whatsappRequireApproval
        ]
      ]
    ]
  }

  /// Update ~/.whatsapp-mcp/settings.json so the WhatsApp MCP + daemon
  /// see the same require_approval value the user just toggled. We
  /// read-then-write (only touching `require_approval`) to preserve
  /// every other field the daemon owns there — daily_cap,
  /// min_staged_age_ms, draft_ttl_days, message_retention_days, the
  /// rate-limit knobs, etc. Clobbering those would reset the user's
  /// rate-limit posture every time they toggle a single switch.
  private func mirrorIntoWhatsAppMcpSettings() {
    let dir = whatsappMcpFile.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    var doc: [String: Any]
    if FileManager.default.fileExists(atPath: whatsappMcpFile.path),
       let data = try? Data(contentsOf: whatsappMcpFile),
       let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      doc = existing
    } else {
      // Daemon hasn't run yet (or its file is corrupt). Write a doc
      // with JUST require_approval; the daemon's Zod schema will fill
      // every other field with its default on next read.
      doc = [:]
    }
    doc["require_approval"] = whatsappRequireApproval

    do {
      let data = try JSONSerialization.data(
        withJSONObject: doc,
        options: [.prettyPrinted, .sortedKeys]
      )
      try data.write(to: whatsappMcpFile, options: .atomic)
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: whatsappMcpFile.path)
    } catch {
      lastError = "couldn't update WhatsApp daemon settings: \(error.localizedDescription)"
    }
  }
}
