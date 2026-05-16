import Foundation
import AppKit

// Probes whether the current process has Full Disk Access by attempting
// to read a known FDA-gated path. We can't probe ON BEHALF OF the
// `imessage-mcp` binary (it's a separate code-signed identity with its
// own TCC entry), but the menu bar app and the MCP binary are installed
// as a pair from the same repo. In practice, users grant FDA to both at
// the same time, and the menu bar's probe is a useful proxy for "did
// the user grant FDA to anything yet."
//
// The probe is best-effort and intentionally cheap. False negatives —
// banner appears when FDA is actually granted on the MCP binary but
// not the menu bar — are recoverable: the user clicks "Recheck" after
// granting, and the banner clears.
enum FDAState: Equatable {
  case granted
  case denied
  case unknown
}

enum FDAProbe {
  // ~/Library/Messages is FDA-gated and exists on every Mac that has
  // ever had iMessage enabled. `contentsOfDirectory` on it throws
  // NSCocoaError 257 (NSFileReadNoPermissionError) without FDA, succeeds
  // with FDA. We use that as a binary indicator. Falling back to
  // `unknown` (not `denied`) on any non-permission error means a user
  // who has never enabled iMessage doesn't get a misleading banner.
  static func probe() -> FDAState {
    guard let libURL = FileManager.default
      .urls(for: .libraryDirectory, in: .userDomainMask).first
    else {
      return .unknown
    }
    let messagesURL = libURL.appendingPathComponent("Messages")
    do {
      _ = try FileManager.default.contentsOfDirectory(atPath: messagesURL.path)
      return .granted
    } catch let error as NSError where error.code == NSFileReadNoPermissionError {
      return .denied
    } catch {
      return .unknown
    }
  }

  // Deep-link into System Settings → Privacy & Security → Full Disk
  // Access. Works on macOS 13+; the URL scheme has been stable since
  // macOS Ventura's System Settings rewrite. The fallback path
  // (`Privacy_FullDiskAccess`) is sometimes mentioned in Apple docs but
  // `Privacy_AllFiles` is the canonical anchor.
  static func openFullDiskAccessPane() {
    let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    if let url = URL(string: urlString) {
      NSWorkspace.shared.open(url)
    }
  }
}
