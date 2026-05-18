import Foundation

// Sends an iMessage by spawning osascript with the same AppleScript the
// MCP server's send_draft tool uses. The duplication is small
// (~30 lines of AppleScript) and avoids inventing an IPC channel between
// the menu bar app and the (stdio-only) MCP server.
//
// TCC note: the first call from this app triggers a macOS prompt asking
// the user to allow "Messages for AI.app" to control "Messages.app".
// That permission is independent from the MCP server's grant — same TCC
// service ("Automation"), separate per-app entry.

struct SendResult {
  let ok: Bool
  let service: String?  // "iMessage" | "SMS" | nil on failure
  let error: String?
  let durationMs: Int
}

enum DraftSender {
  private static let timeoutSeconds: TimeInterval = 20

  private static let script = """
  on run argv
    set theAddress to item 1 of argv
    set theMessage to item 2 of argv
    tell application "Messages"
      try
        set theService to first service whose service type is iMessage
        set theBuddy to buddy theAddress of theService
        send theMessage to theBuddy
        return "iMessage"
      on error errMsg number errNum
        try
          set smsService to first service whose service type is SMS
          set smsBuddy to buddy theAddress of smsService
          send theMessage to smsBuddy
          return "SMS"
        on error smsErr number smsNum
          return "ERROR: iMessage=" & errMsg & " (errNum=" & errNum & "); SMS=" & smsErr & " (errNum=" & smsNum & ")"
        end try
      end try
    end tell
  end run
  """

  static func send(toHandle: String, body: String) async -> SendResult {
    let started = Date()
    return await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script, toHandle, body]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let timeoutWork = DispatchWorkItem {
          if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: timeoutWork)

        do {
          try process.run()
          process.waitUntilExit()
          timeoutWork.cancel()
        } catch {
          let elapsed = Int(Date().timeIntervalSince(started) * 1000)
          continuation.resume(returning: SendResult(
            ok: false, service: nil,
            error: "osascript spawn failed: \(error.localizedDescription)",
            durationMs: elapsed
          ))
          return
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: outData, encoding: .utf8)?
          .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: errData, encoding: .utf8)?
          .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)

        if process.terminationStatus != 0 {
          continuation.resume(returning: SendResult(
            ok: false, service: nil,
            error: stderr.isEmpty ? "osascript exited with code \(process.terminationStatus)" : stderr,
            durationMs: elapsed
          ))
          return
        }

        if stdout == "iMessage" || stdout == "SMS" {
          continuation.resume(returning: SendResult(
            ok: true, service: stdout, error: nil, durationMs: elapsed
          ))
          return
        }

        continuation.resume(returning: SendResult(
          ok: false, service: nil,
          error: stdout.isEmpty ? "unknown osascript output" : stdout,
          durationMs: elapsed
        ))
      }
    }
  }
}
