import Foundation

// Platform-aware send dispatch. Holds the iMessage AppleScript path
// AND the WhatsApp daemon-socket path. Routes by the draft's
// `effectivePlatform`:
//
//   .imessage → osascript → Messages.app (existing path, unchanged)
//   .whatsapp → ~/.whatsapp-mcp/daemon.sock JSON-RPC →
//               approveDraft + sendDraft → Baileys → WhatsApp servers
//
// iMessage notes carry over from v0.2.x:
// - The duplication of AppleScript here vs the MCP's send_draft tool is
//   ~30 lines; preferable to inventing an IPC channel between the menu
//   bar app and the (stdio-only) MCP server.
// - First call from this app triggers a macOS prompt asking the user
//   to allow "Messages for AI.app" to control "Messages.app". That
//   permission is independent from the MCP server's grant — same TCC
//   service ("Automation"), separate per-app entry.
//
// WhatsApp notes:
// - The daemon is the source of truth for the sent state. On success
//   it writes `sent_at` to the draft JSON; the menubar's DraftStore FS
//   watcher then refreshes within ~100 ms. The menubar must NOT call
//   `store.markSent(...)` for WhatsApp drafts (markSent throws
//   `platformMismatch` if it's called with a WhatsApp draft).
// - Approval is a separate daemon call that precedes send. The
//   approveDraft → sendDraft sequence is intentional: a corrupted
//   approve step blocks the send rather than silently sending an
//   unapproved draft. The daemon also re-checks approval_state inside
//   sendDraft as a belt-and-suspenders gate.

/// Result of a send call. `service` is platform-specific:
/// - iMessage: "iMessage" | "SMS" (which transport Messages.app used)
/// - WhatsApp: "WhatsApp"
/// - nil on failure
struct SendResult {
  let ok: Bool
  let service: String?
  let error: String?
  let durationMs: Int
  /// For WhatsApp sends: the daemon's `message_id` for the delivered
  /// message. iMessage sends don't get a message_id back from
  /// AppleScript. nil otherwise.
  let messageId: String?

  init(ok: Bool, service: String?, error: String?, durationMs: Int, messageId: String? = nil) {
    self.ok = ok
    self.service = service
    self.error = error
    self.durationMs = durationMs
    self.messageId = messageId
  }
}

enum DraftSender {
  private static let timeoutSeconds: TimeInterval = 20

  // MARK: - Platform dispatch

  /// Top-level send entrypoint. Routes to the correct platform-specific
  /// path based on the draft's `effectivePlatform`.
  ///
  /// For iMessage: synchronous-ish (we await the osascript exit).
  /// Returns SendResult with `service` of "iMessage" or "SMS"; caller
  /// (DraftRowView) is responsible for calling
  /// `store.markSent(id:sentAt:service:)` to persist sent_at.
  ///
  /// For WhatsApp: makes two daemon RPC calls (approveDraft + sendDraft);
  /// the daemon writes sent_at to disk itself. Caller MUST NOT call
  /// markSent — DraftStore's FS watcher picks up the change.
  static func send(draft: Draft) async -> SendResult {
    switch draft.effectivePlatform {
    case .imessage:
      return await sendIMessage(toHandle: draft.to_handle, body: draft.body)
    case .whatsapp:
      return await sendWhatsApp(draftId: draft.id)
    }
  }

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

  // MARK: - WhatsApp path

  /// Approve + send via the WhatsApp daemon over its Unix socket. The
  /// daemon persists the resulting `sent_at` to the draft JSON; we
  /// don't write to disk here. Caller (DraftRowView) MUST NOT call
  /// `store.markSent(...)` after a successful WhatsApp send — the FS
  /// watcher takes care of it. (Calling markSent on a WhatsApp draft
  /// would throw `platformMismatch` regardless.)
  private static func sendWhatsApp(draftId: String) async -> SendResult {
    let started = Date()
    do {
      _ = try await WhatsAppRPCClient.approveDraft(id: draftId)
      let result = try await WhatsAppRPCClient.sendDraft(id: draftId)
      let elapsed = Int(Date().timeIntervalSince(started) * 1000)
      if result.ok {
        return SendResult(ok: true, service: "WhatsApp", error: nil, durationMs: elapsed, messageId: result.message_id)
      } else {
        return SendResult(ok: false, service: nil, error: "daemon returned ok=false", durationMs: elapsed)
      }
    } catch let e as WhatsAppRPCClient.RPCError {
      let elapsed = Int(Date().timeIntervalSince(started) * 1000)
      return SendResult(ok: false, service: nil, error: e.description, durationMs: elapsed)
    } catch {
      let elapsed = Int(Date().timeIntervalSince(started) * 1000)
      return SendResult(ok: false, service: nil, error: error.localizedDescription, durationMs: elapsed)
    }
  }

  // MARK: - iMessage path

  /// Send via osascript + Messages.app. Existing v0.2.x behavior,
  /// unchanged. Renamed from `send(toHandle:body:)` to make the
  /// dispatch explicit; the only call site (DraftSender.send(draft:))
  /// is internal to this file.
  private static func sendIMessage(toHandle: String, body: String) async -> SendResult {
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
