import Foundation
import Combine
import Darwin

/// Spawns + monitors the `imessage-drafts-daemon` binary that ships inside
/// the Messages for AI .app bundle.
///
/// Why this exists: the Claude-launched iMessage MCP can't get Full Disk
/// Access — macOS attributes a child process's FDA to its *launcher*
/// (Claude / claude-code), not to the `Messages for AI` bundle grant the
/// MCP is signed under. But the menu-bar app DOES hold that grant, so a
/// daemon IT launches inherits FDA for chat.db. The daemon performs the
/// FDA-gated reads on the MCP's behalf (the MCP talks to it over a Unix
/// socket once the full refactor lands).
///
/// Mirrors `WhatsAppDaemonController` — same supervision (reap-stale-pid,
/// pipe→rotating log, exponential-backoff respawn, SIGTERM-on-quit) minus
/// the Baileys connection-state polling, since the iMessage daemon has no
/// live connection (it's a read-only chat.db query server).
@MainActor
final class IMessageDaemonController: ObservableObject {
  enum Status: Equatable {
    case idle
    case starting
    case running(pid: Int32)
    case backingOff(nextAttemptIn: TimeInterval, consecutiveCrashes: Int)
    case crashLooping(consecutiveCrashes: Int)
    case stopped
  }

  @Published private(set) var status: Status = .idle
  @Published private(set) var lastError: String?

  private let maxConsecutiveCrashes = 5
  private let stableRunSeconds: TimeInterval = 30
  private let backoffSchedule: [TimeInterval] = [1, 2, 4, 8, 16, 32, 60]
  private let logRotateBytes: Int = 10 * 1024 * 1024
  private let logRotateKeep = 3

  private var process: Process?
  private var stdoutPipe: Pipe?
  private var stderrPipe: Pipe?
  private var logHandle: FileHandle?
  private var consecutiveCrashes = 0
  private var lastStartAt: Date?
  private var pendingRespawn: Task<Void, Never>?

  private let binaryName = "imessage-drafts-daemon"
  private let stateDirName = ".messages-mcp"
  private let logFileName = "imessage-daemon.log"

  // MARK: - Public API

  func start() {
    pendingRespawn?.cancel()
    pendingRespawn = nil
    switch status {
    case .running, .starting:
      return
    case .idle, .stopped, .backingOff, .crashLooping:
      consecutiveCrashes = 0
      lastError = nil
      launch()
    }
  }

  func stop() async {
    pendingRespawn?.cancel()
    pendingRespawn = nil
    guard let proc = process, proc.isRunning else {
      status = .stopped
      return
    }
    let pid = proc.processIdentifier
    kill(pid, SIGTERM)
    let deadline = Date().addingTimeInterval(5)
    while proc.isRunning && Date() < deadline {
      try? await Task.sleep(nanoseconds: 100_000_000)
    }
    if proc.isRunning {
      kill(pid, SIGKILL)
      try? await Task.sleep(nanoseconds: 200_000_000)
    }
    status = .stopped
  }

  /// Synchronous quit path (NSApplicationWillTerminate is sync).
  func stopBlocking() {
    let sem = DispatchSemaphore(value: 0)
    Task { @MainActor in
      await stop()
      sem.signal()
    }
    _ = sem.wait(timeout: .now() + 6)
  }

  // MARK: - reap stale daemon

  private func reapStaleDaemonIfNeeded() {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let pidFile = home.appendingPathComponent("\(stateDirName)/daemon.pid")
    let sockFile = home.appendingPathComponent("\(stateDirName)/daemon.sock")
    guard let pidStr = try? String(contentsOf: pidFile, encoding: .utf8) else { return }
    let trimmed = pidStr.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let stalePid = pid_t(trimmed), stalePid > 0 else { return }
    if kill(stalePid, 0) != 0 { return }
    appendLogLine("[controller] reaping stale daemon at PID \(stalePid) before launch")
    kill(stalePid, SIGTERM)
    let deadline = Date().addingTimeInterval(2)
    while kill(stalePid, 0) == 0 && Date() < deadline {
      Thread.sleep(forTimeInterval: 0.1)
    }
    if kill(stalePid, 0) == 0 {
      appendLogLine("[controller] stale daemon \(stalePid) ignored SIGTERM, sending SIGKILL")
      kill(stalePid, SIGKILL)
      Thread.sleep(forTimeInterval: 0.2)
    }
    try? FileManager.default.removeItem(at: pidFile)
    try? FileManager.default.removeItem(at: sockFile)
  }

  // MARK: - launch + monitor

  private func launch() {
    guard let binURL = resolveDaemonBinary() else {
      status = .idle
      lastError = "could not locate \(binaryName) binary"
      NSLog("[imessage-daemon] launch aborted: could not locate \(binaryName) under \(Bundle.main.bundleURL.path)")
      return
    }
    NSLog("[imessage-daemon] launching \(binURL.path)")
    reapStaleDaemonIfNeeded()

    let proc = Process()
    proc.executableURL = binURL
    proc.arguments = []

    let outPipe = Pipe()
    let errPipe = Pipe()
    proc.standardOutput = outPipe
    proc.standardError = errPipe

    let logFile = ensureLogFileOpen()
    self.logHandle = logFile

    let writeLog: @Sendable (FileHandle) -> Void = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      Task { @MainActor in
        self?.appendToLog(data)
      }
    }
    outPipe.fileHandleForReading.readabilityHandler = writeLog
    errPipe.fileHandleForReading.readabilityHandler = writeLog
    self.stdoutPipe = outPipe
    self.stderrPipe = errPipe

    proc.terminationHandler = { [weak self] terminated in
      let s = terminated.terminationStatus
      let r = terminated.terminationReason
      Task { @MainActor in
        self?.handleTermination(exitStatus: s, reason: r)
      }
    }

    do {
      try proc.run()
    } catch {
      lastError = "failed to launch daemon: \(error.localizedDescription)"
      status = .idle
      NSLog("[imessage-daemon] proc.run() failed: \(error)")
      return
    }

    self.process = proc
    self.lastStartAt = Date()
    status = .starting

    // Promote to .running once it's stayed up ~1.2s. No socket to wait on
    // (the spike daemon is log-only); a startup crash — e.g. a PID-lock
    // conflict — fires terminationHandler first and we back off instead.
    Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 1_200_000_000)
      guard let self = self else { return }
      guard case .starting = self.status else { return }
      guard let p = self.process, p.isRunning else { return }
      self.status = .running(pid: p.processIdentifier)
    }
  }

  private func handleTermination(exitStatus: Int32, reason: Process.TerminationReason) {
    stdoutPipe?.fileHandleForReading.readabilityHandler = nil
    stderrPipe?.fileHandleForReading.readabilityHandler = nil
    stdoutPipe = nil
    stderrPipe = nil
    process = nil

    if case .stopped = status { return }

    let ranFor = lastStartAt.map { Date().timeIntervalSince($0) } ?? 0
    if ranFor >= stableRunSeconds { consecutiveCrashes = 0 }
    consecutiveCrashes += 1

    appendLogLine("[daemon] exited status=\(exitStatus) reason=\(reason.rawValue) ranFor=\(Int(ranFor))s consecutiveCrashes=\(consecutiveCrashes)")

    if consecutiveCrashes >= maxConsecutiveCrashes {
      status = .crashLooping(consecutiveCrashes: consecutiveCrashes)
      lastError = "iMessage daemon crashed \(consecutiveCrashes) times in a row. Tap Start to retry."
      return
    }

    let idx = min(consecutiveCrashes - 1, backoffSchedule.count - 1)
    let delay = backoffSchedule[idx]
    status = .backingOff(nextAttemptIn: delay, consecutiveCrashes: consecutiveCrashes)

    pendingRespawn = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      guard let self = self, !Task.isCancelled else { return }
      switch self.status {
      case .stopped, .running, .starting: return
      default: break
      }
      self.launch()
    }
  }

  // MARK: - binary resolution

  private func resolveDaemonBinary() -> URL? {
    let bundle = Bundle.main.bundleURL
    let inBundle = bundle
      .appendingPathComponent("Contents/MacOS")
      .appendingPathComponent(binaryName)
    if FileManager.default.isExecutableFile(atPath: inBundle.path) {
      return inBundle
    }
    let sibling = bundle.deletingLastPathComponent().appendingPathComponent(binaryName)
    if FileManager.default.isExecutableFile(atPath: sibling.path) {
      return sibling
    }
    return nil
  }

  // MARK: - log rotation

  private func logFileURL() -> URL {
    let dir = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(stateDirName)
      .appendingPathComponent("logs")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent(logFileName)
  }

  private func ensureLogFileOpen() -> FileHandle? {
    let url = logFileURL()
    rotateIfNeeded(at: url)
    if !FileManager.default.fileExists(atPath: url.path) {
      FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
    }
    return try? FileHandle(forWritingTo: url)
  }

  private func rotateIfNeeded(at url: URL) {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
          let size = attrs[.size] as? Int,
          size >= logRotateBytes
    else { return }
    let fm = FileManager.default
    let oldest = url.appendingPathExtension("\(logRotateKeep)")
    try? fm.removeItem(at: oldest)
    for i in stride(from: logRotateKeep - 1, through: 1, by: -1) {
      let src = url.appendingPathExtension("\(i)")
      let dst = url.appendingPathExtension("\(i + 1)")
      if fm.fileExists(atPath: src.path) {
        try? fm.moveItem(at: src, to: dst)
      }
    }
    try? fm.moveItem(at: url, to: url.appendingPathExtension("1"))
  }

  private func appendToLog(_ data: Data) {
    guard let handle = logHandle else { return }
    _ = try? handle.seekToEnd()
    handle.write(data)
  }

  private func appendLogLine(_ line: String) {
    let timestamped = "[\(ISO8601DateFormatter().string(from: Date()))] \(line)\n"
    if let data = timestamped.data(using: .utf8) {
      appendToLog(data)
    }
  }
}
