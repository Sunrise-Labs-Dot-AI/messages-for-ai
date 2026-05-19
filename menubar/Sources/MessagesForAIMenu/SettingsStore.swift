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

  @Published private(set) var lastError: String?

  private let file: URL

  init() {
    let dir = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".messages-mcp")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    self.file = dir.appendingPathComponent("settings.json")

    let loaded = Self.load(from: file)
    self.requireApproval = loaded.requireApproval
    self.firstRunComplete = loaded.firstRunComplete
    self.imessageEnabled = loaded.imessageEnabled
    self.whatsappEnabled = loaded.whatsappEnabled

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
    /// True when the on-disk file is missing or was v1; tells init() to
    /// write the canonical v2 schema immediately.
    let requiresMigrationWrite: Bool
  }

  private static func load(from file: URL) -> LoadedState {
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
        requiresMigrationWrite: true
      )
    }

    let schemaVersion = json["schema_version"] as? Int ?? 1

    if schemaVersion >= 2 {
      // v2 reader. Tolerate missing fields with safe defaults.
      let transports = json["transports"] as? [String: Any] ?? [:]
      let imessage = transports["imessage"] as? [String: Any] ?? [:]
      let whatsapp = transports["whatsapp"] as? [String: Any] ?? [:]
      return LoadedState(
        requireApproval: imessage["require_approval"] as? Bool ?? true,
        firstRunComplete: json["first_run_complete"] as? Bool ?? false,
        imessageEnabled: imessage["enabled"] as? Bool ?? true,
        whatsappEnabled: whatsapp["enabled"] as? Bool ?? false,
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
      requiresMigrationWrite: true
    )
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
          "enabled": whatsappEnabled
        ]
      ]
    ]
  }
}
