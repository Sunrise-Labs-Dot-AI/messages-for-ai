import Foundation
import Combine

// Reads + writes ~/.imessage-mcp/settings.json. The MCP server reads
// the same file on every send_imessage_draft call (no caching), so
// toggling here takes effect immediately for the next send attempt
// from any MCP client.
//
// Schema mirrors `Settings` in src/storage/settings.ts. Keep keys in
// sync; unknown keys are ignored on both sides for forward-compat.
@MainActor
final class SettingsStore: ObservableObject {
  // When true (default), the MCP send_imessage_draft tool refuses and
  // the user must hold the Send button in the menu bar UI to dispatch
  // each draft. The strongest enforcement of the draft-review property.
  @Published var requireApproval: Bool {
    didSet { persist() }
  }

  @Published private(set) var lastError: String?

  private let file: URL

  init() {
    let dir = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".imessage-mcp")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    self.file = dir.appendingPathComponent("settings.json")

    // Default-safe load. If the file doesn't exist, doesn't parse, or
    // doesn't include the field, we land on require_approval=true.
    if FileManager.default.fileExists(atPath: file.path),
       let data = try? Data(contentsOf: file),
       let parsed = try? JSONDecoder().decode(SettingsFile.self, from: data) {
      self.requireApproval = parsed.require_approval ?? true
    } else {
      self.requireApproval = true
      // Persist the defaults on first run so the MCP server has a file
      // to read rather than having to assume defaults itself.
      persistInit()
    }
  }

  private func persistInit() {
    // Same as persist() but doesn't go through didSet (which would fire
    // during init before self is fully constructed).
    do {
      let data = try JSONEncoder().encode(currentFile())
      try data.write(to: file, options: .atomic)
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    } catch {
      lastError = "couldn't write settings.json: \(error.localizedDescription)"
    }
  }

  private func persist() {
    do {
      let data = try JSONEncoder().encode(currentFile())
      try data.write(to: file, options: .atomic)
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
      lastError = nil
    } catch {
      lastError = "couldn't write settings.json: \(error.localizedDescription)"
    }
  }

  private func currentFile() -> SettingsFile {
    SettingsFile(require_approval: requireApproval)
  }
}

// The on-disk shape. require_approval is consumed by both the Swift menu
// bar app AND the TS MCP server, so keep the snake_case name in sync
// with src/storage/settings.ts.
private struct SettingsFile: Codable {
  let require_approval: Bool?
}
