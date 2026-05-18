import Foundation
import Darwin

/// Thin JSON-RPC 2.0 client over the WhatsApp daemon's Unix socket at
/// `~/.whatsapp-mcp/daemon.sock`. Speaks newline-delimited frames.
///
/// One connection per call: the menubar's traffic is request/response
/// (approve, send, occasional discard) — there's no benefit to keeping
/// a persistent socket for these. The pairing flow that needs streaming
/// (`subscribe("qr")`) ships in a separate file (`WhatsAppPairingView`)
/// and manages its own long-lived connection.
///
/// Peer authentication is enforced on the daemon side: `~/.whatsapp-mcp/
/// daemon.sock` is reachable by every process running as the user, so
/// the daemon checks the peer's code-signing identity per connection
/// against `PEER_ALLOWED_REQUIREMENTS` (empty in the unreleased dev
/// build → daemon must run with `WHATSAPP_MCP_DEV=1` to allow any
/// peer). The release pipeline will populate that allowlist with the
/// menu bar app bundle's designated requirement. From the client side
/// there's nothing to do — failed peer-auth surfaces as a closed
/// connection / EOF.
enum WhatsAppRPCClient {
  /// Default 10s timeout. Longer than the daemon's own send timeout
  /// (Baileys can take a few seconds) but short enough that a stuck
  /// daemon doesn't hang the menubar UI forever.
  static let timeoutSeconds: TimeInterval = 10

  /// Socket path. Constructed at call time (not cached) so an unset
  /// HOME doesn't crash module load.
  private static var socketPath: String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return "\(home)/.whatsapp-mcp/daemon.sock"
  }

  // MARK: - Convenience methods (one per daemon RPC the menubar uses)

  /// Mark a draft `approval_state: "approved"`. The daemon refuses to
  /// `sendDraft` until this returns success. Called by the menubar's
  /// hold-to-fire interaction BEFORE `sendDraft`.
  static func approveDraft(id: String) async throws -> ApproveResult {
    let params = DraftIdParams(draft_id: id)
    let raw = try await call(method: "approveDraft", params: params)
    return try JSONDecoder().decode(ApproveResult.self, from: raw)
  }

  /// Tell the daemon to send a previously-approved draft. The daemon
  /// writes `sent_at` to the draft JSON on success; the menubar's
  /// `DraftStore` FS watcher then refreshes and the row renders as
  /// sent. Menubar must NOT write `sent_at` itself for WhatsApp drafts.
  static func sendDraft(id: String) async throws -> SendResult {
    let params = DraftIdParams(draft_id: id)
    let raw = try await call(method: "sendDraft", params: params)
    return try JSONDecoder().decode(SendResult.self, from: raw)
  }

  /// Wipe the daemon's Baileys session + remove the LOGGED_OUT
  /// sentinel so the daemon can re-pair on next start. Used by the
  /// pairing sheet's "Reconnect" flow when the user has been remotely
  /// logged out. Destructive — confirm with the user before calling.
  static func unlinkAndReset() async throws {
    // Daemon returns `{ok: true, note: "..."}`; we don't need the body.
    _ = try await call(method: "unlinkAndReset", params: EmptyParams())
  }

  private struct EmptyParams: Encodable {}

  // MARK: - Wire types

  struct DraftIdParams: Encodable {
    let draft_id: String
  }

  struct ApproveResult: Decodable {
    // Daemon returns `{ draft: {...full draft after the state mutation...} }`
    // We don't currently use the returned draft (FS watcher re-reads
    // from disk) but decoding it confirms the daemon understood the
    // call. Kept loose (Decodable + no fields) since we just need the
    // success signal.
  }

  struct SendResult: Decodable {
    let ok: Bool
    let draft_id: String?
    let message_id: String?
    let sent_at: String?
  }

  // MARK: - Errors

  enum RPCError: Error, CustomStringConvertible {
    case daemonNotInstalled            // socket file does not exist
    case daemonNotRunning              // socket exists but connect refused (ECONNREFUSED)
    case peerAuthRejected              // daemon closed connection after our write — usually peer-auth
    case timeout                       // no response within timeoutSeconds
    case socketError(errno: Int32, op: String)
    case writeError(Error)
    case readError(Error)
    case invalidResponse(String)       // not parseable JSON-RPC 2.0
    case rpcError(code: Int, message: String)

    var description: String {
      switch self {
      case .daemonNotInstalled:
        return "WhatsApp daemon socket not found at ~/.whatsapp-mcp/daemon.sock. Install whatsapp-mcp from https://github.com/Sunrise-Labs-Dot-AI/whatsapp-mcp"
      case .daemonNotRunning:
        return "WhatsApp daemon socket exists but is not accepting connections. Is the daemon running? (Check: launchctl list | grep whatsapp-mcp)"
      case .peerAuthRejected:
        return "WhatsApp daemon rejected this binary. The menubar app's code-signing identity may not be on the daemon's PEER_ALLOWED_REQUIREMENTS allowlist."
      case .timeout:
        return "WhatsApp daemon did not respond within \(Int(timeoutSeconds))s"
      case .socketError(let errno, let op):
        return "socket \(op) failed: errno \(errno) (\(String(cString: strerror(errno))))"
      case .writeError(let e):
        return "write to daemon socket failed: \(e.localizedDescription)"
      case .readError(let e):
        return "read from daemon socket failed: \(e.localizedDescription)"
      case .invalidResponse(let s):
        return "daemon returned a frame that's not valid JSON-RPC 2.0: \(s)"
      case .rpcError(let code, let message):
        return "daemon RPC error \(code): \(message)"
      }
    }
  }

  // MARK: - JSON-RPC plumbing

  private struct RPCRequest<P: Encodable>: Encodable {
    let jsonrpc = "2.0"
    let id: String
    let method: String
    let params: P
  }

  /// JSON-RPC 2.0 response envelope. Exactly one of `result` / `error`
  /// is present. We decode the envelope first, then re-decode `result`
  /// into the caller-typed struct (returned to the caller as raw Data).
  private struct RPCResponseEnvelope: Decodable {
    let jsonrpc: String
    let id: String?
    let result: AnyDecodable?
    let error: RPCErrorPayload?
  }

  private struct RPCErrorPayload: Decodable {
    let code: Int
    let message: String
  }

  // Type-erased Decodable that just stashes the raw subdocument so we
  // can re-encode it for the caller's strongly-typed decode pass.
  private struct AnyDecodable: Decodable {
    let raw: Data
    init(from decoder: Decoder) throws {
      let c = try decoder.singleValueContainer()
      // Pull through as a generic JSON Codable bridge by re-encoding.
      // The simpler path (capturing the underlying Data directly from
      // the decoder) isn't available with JSONDecoder, so we decode to
      // a permissive Any-like and re-encode.
      if let v = try? c.decode(JSONValue.self) {
        self.raw = try JSONEncoder().encode(v)
      } else {
        self.raw = Data()
      }
    }
  }

  /// Send one JSON-RPC call. Returns the raw `result` payload as Data
  /// (which the caller decodes into a method-specific result struct).
  private static func call<P: Encodable>(method: String, params: P) async throws -> Data {
    let path = socketPath

    // Fail fast on common "not installed / not running" cases with a
    // specific error so the UI can give a helpful message instead of
    // a generic ECONNREFUSED.
    if !FileManager.default.fileExists(atPath: path) {
      throw RPCError.daemonNotInstalled
    }

    let requestId = UUID().uuidString
    let request = RPCRequest(id: requestId, method: method, params: params)
    let payload = try JSONEncoder().encode(request) + Data([0x0a]) // newline-delimited

    return try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          let raw = try sendOneFrame(path: path, payload: payload)
          let envelope = try JSONDecoder().decode(RPCResponseEnvelope.self, from: raw)
          if let err = envelope.error {
            continuation.resume(throwing: RPCError.rpcError(code: err.code, message: err.message))
            return
          }
          guard let result = envelope.result else {
            continuation.resume(throwing: RPCError.invalidResponse("response had neither `result` nor `error`"))
            return
          }
          continuation.resume(returning: result.raw)
        } catch let e as RPCError {
          continuation.resume(throwing: e)
        } catch {
          continuation.resume(throwing: RPCError.readError(error))
        }
      }
    }
  }

  /// Synchronous connect → write → read-one-line → close. Runs on a
  /// background queue from `call(...)`.
  private static func sendOneFrame(path: String, payload: Data) throws -> Data {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    if fd < 0 { throw RPCError.socketError(errno: errno, op: "socket()") }
    defer { close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = path.utf8CString
    // sockaddr_un.sun_path is 104 bytes on Darwin.
    guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
      throw RPCError.socketError(errno: ENAMETOOLONG, op: "path too long")
    }
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
      ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
        for (i, b) in pathBytes.enumerated() { dest[i] = b }
      }
    }
    let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
    let connectResult = withUnsafePointer(to: &addr) { addrPtr in
      addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
        Darwin.connect(fd, sockaddrPtr, addrLen)
      }
    }
    if connectResult < 0 {
      switch errno {
      case ECONNREFUSED, ENOENT: throw RPCError.daemonNotRunning
      default: throw RPCError.socketError(errno: errno, op: "connect()")
      }
    }

    // Apply send + recv timeouts via SO_SNDTIMEO / SO_RCVTIMEO. Cheaper
    // than a separate watchdog thread.
    var tv = timeval(
      tv_sec: Int(timeoutSeconds),
      tv_usec: Int32((timeoutSeconds - Double(Int(timeoutSeconds))) * 1_000_000)
    )
    _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    // Write the entire payload.
    var written = 0
    payload.withUnsafeBytes { (rawBuf: UnsafeRawBufferPointer) in
      let base = rawBuf.baseAddress!
      while written < payload.count {
        let n = Darwin.write(fd, base.advanced(by: written), payload.count - written)
        if n <= 0 { break }
        written += n
      }
    }
    if written != payload.count {
      if errno == EAGAIN || errno == EWOULDBLOCK { throw RPCError.timeout }
      throw RPCError.socketError(errno: errno, op: "write()")
    }

    // Read until we see a newline. Daemon frames are tiny (KB-range)
    // so a single 4 KiB buffer + concat-into-Data loop is fine.
    var buffer = Data()
    let chunkSize = 4096
    var chunk = [UInt8](repeating: 0, count: chunkSize)
    while true {
      let n = chunk.withUnsafeMutableBufferPointer { ptr in
        Darwin.read(fd, ptr.baseAddress, chunkSize)
      }
      if n == 0 {
        // EOF before newline — typically peer-auth rejection (daemon
        // closes the connection without responding).
        if buffer.isEmpty { throw RPCError.peerAuthRejected }
        break
      }
      if n < 0 {
        if errno == EAGAIN || errno == EWOULDBLOCK { throw RPCError.timeout }
        throw RPCError.socketError(errno: errno, op: "read()")
      }
      buffer.append(chunk, count: n)
      if buffer.contains(0x0a) { break }
    }

    // Trim the newline terminator(s) so JSONDecoder gets a clean frame.
    while let last = buffer.last, last == 0x0a || last == 0x0d {
      buffer.removeLast()
    }
    return buffer
  }
}

// MARK: - Permissive JSON value

/// JSON value Decodable + Encodable bridge used by `AnyDecodable` to
/// round-trip an unknown subdocument without losing fidelity. Standard
/// library doesn't ship one; this is the minimal version covering all
/// six JSON types.
fileprivate enum JSONValue: Codable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() { self = .null; return }
    if let b = try? c.decode(Bool.self) { self = .bool(b); return }
    if let n = try? c.decode(Double.self) { self = .number(n); return }
    if let s = try? c.decode(String.self) { self = .string(s); return }
    if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
    if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
    throw DecodingError.dataCorruptedError(in: c, debugDescription: "unrecognized JSON value")
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .null: try c.encodeNil()
    case .bool(let b): try c.encode(b)
    case .number(let n): try c.encode(n)
    case .string(let s): try c.encode(s)
    case .array(let a): try c.encode(a)
    case .object(let o): try c.encode(o)
    }
  }
}
