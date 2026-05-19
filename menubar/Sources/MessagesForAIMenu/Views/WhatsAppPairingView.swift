import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit

/// First-time pairing sheet for the WhatsApp daemon. Opens a streaming
/// JSON-RPC `subscribe("qr")` session against `~/.whatsapp-mcp/
/// daemon.sock`, renders pushed QR codes for the user to scan with
/// WhatsApp on their phone (Settings → Linked Devices → Link a Device),
/// and auto-dismisses when the daemon reports `state: "connected"`.
///
/// State machine:
/// ```
/// .checkingSentinel  ─── if LOGGED_OUT sentinel exists ──→ .loggedOutRecovery
///         │
///         ↓ (no sentinel)
///   .subscribing  ── daemon error / not running ──→ .error(...)
///         │
///         ↓ (subscribed)
///   .awaitingFirstQR
///         │
///         ↓ (qr.update)
///   .awaitingScan(qr) ←─── qr.update (re-issued every ~20s by WhatsApp)
///         │
///         ↓ (state.update: connecting)
///   .pairingHandshake
///         │
///         ↓ (state.update: connected)
///   .connected → sheet auto-dismisses after a brief success state
/// ```
///
/// The loggedOutRecovery branch presents a confirmation + invokes
/// `unlinkAndReset` then drops back to `.subscribing` for a fresh pair.
struct WhatsAppPairingView: View {
  /// Bound to the parent's @State Bool that controls sheet presentation.
  /// We set it to false from inside the sheet to dismiss on success.
  @Binding var isPresented: Bool

  @EnvironmentObject var whatsappDaemon: WhatsAppDaemonController

  @State private var phase: Phase = .checkingSentinel
  /// Time at which the currently-displayed QR expires. Drives the
  /// countdown bar. The daemon pushes a fresh QR every ~20 s; we reset
  /// this clock on every `qr.update`.
  @State private var qrExpiresAt: Date = .distantPast
  /// True while the unlinkAndReset confirmation alert is shown.
  @State private var confirmReset: Bool = false
  /// Drives the countdown bar's progress fill. Refreshed by a SwiftUI
  /// timer publisher — see `body`.
  @State private var now: Date = Date()
  private let timer = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

  enum Phase: Equatable {
    case checkingSentinel
    case loggedOutRecovery
    /// Daemon isn't running yet; we kicked .start() and are waiting for
    /// the controller to flip to .running before subscribing.
    case startingDaemon
    case subscribing
    case awaitingFirstQR
    case awaitingScan(qr: String)
    case pairingHandshake
    case connected
    case error(String)
  }

  var body: some View {
    VStack(spacing: 16) {
      header
      Divider()
      content
      Spacer()
      footer
    }
    .padding(20)
    .frame(width: 360, height: 460)
    .onAppear {
      if WhatsAppQRSession.loggedOutSentinelExists {
        phase = .loggedOutRecovery
      } else if isDaemonAlreadyRunning {
        phase = .subscribing
      } else {
        // The .app bundles the daemon. Kick it up; we'll auto-advance
        // to .subscribing as soon as the controller reports .running.
        whatsappDaemon.start()
        phase = .startingDaemon
      }
    }
    .onChange(of: whatsappDaemon.status) { status in
      // While we're waiting for the daemon to come up, watch the
      // controller's status. The .startingDaemon → .subscribing
      // transition fires once on the first .running observation.
      guard case .startingDaemon = phase else { return }
      switch status {
      case .running:
        phase = .subscribing
      case .crashLooping(let count):
        phase = .error("WhatsApp daemon failed to start (\(count) crashes in a row). Check ~/.messages-mcp/logs/whatsapp-daemon.log.")
      default:
        break
      }
    }
    .task(id: shouldRunSubscription) {
      // The .task(id:) modifier restarts the task whenever the id
      // changes. We use that to (re-)start the subscription:
      //  - on initial appear when phase = .subscribing
      //  - again after the user completes unlinkAndReset
      guard shouldRunSubscription else { return }
      await runSubscription()
    }
    .onReceive(timer) { t in
      now = t
    }
    .alert("Wipe local WhatsApp session?", isPresented: $confirmReset) {
      Button("Cancel", role: .cancel) {}
      Button("Reconnect", role: .destructive) {
        Task { await runUnlinkAndReset() }
      }
    } message: {
      Text("This deletes the encrypted session credential at ~/.whatsapp-mcp/session.db so the daemon can re-pair from scratch. Your message history (~/.whatsapp-mcp/messages.db) is preserved.")
    }
  }

  /// Whether the .task should be running the subscribe loop. Computed
  /// from phase so transitions naturally start/stop the task.
  private var shouldRunSubscription: Bool {
    switch phase {
    case .subscribing, .awaitingFirstQR, .awaitingScan, .pairingHandshake:
      return true
    default:
      return false
    }
  }

  // MARK: - Sections

  private var header: some View {
    HStack(spacing: 8) {
      Image(systemName: Platform.whatsapp.sfSymbol)
        .foregroundStyle(Platform.whatsapp.accentColor)
      Text("Connect WhatsApp")
        .font(.headline)
      Spacer()
      Button {
        isPresented = false
      } label: {
        Image(systemName: "xmark.circle.fill")
          .foregroundStyle(.tertiary)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Close")
    }
  }

  @ViewBuilder
  private var content: some View {
    switch phase {
    case .checkingSentinel:
      ProgressView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .loggedOutRecovery:
      loggedOutView
    case .startingDaemon:
      startingDaemonView
    case .subscribing, .awaitingFirstQR:
      waitingForQR
    case .awaitingScan(let qr):
      qrCodeView(qr: qr)
    case .pairingHandshake:
      pairingHandshakeView
    case .connected:
      connectedView
    case .error(let message):
      errorView(message)
    }
  }

  private var startingDaemonView: some View {
    VStack(spacing: 12) {
      ProgressView()
      Text("Starting WhatsApp daemon…")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  /// True if the daemon's WhatsAppDaemonController already considers it
  /// running. Avoids the brief "Starting…" flash when the user re-opens
  /// the pairing sheet on an already-paired session.
  private var isDaemonAlreadyRunning: Bool {
    if case .running = whatsappDaemon.status { return true }
    return false
  }

  @ViewBuilder
  private var footer: some View {
    Group {
      switch phase {
      case .awaitingScan:
        Text("Open WhatsApp on your phone → Settings → Linked Devices → Link a Device, then scan this QR.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      case .error:
        // No footer help — error view handles its own messaging.
        EmptyView()
      default:
        EmptyView()
      }
    }
  }

  // MARK: - Phase views

  private var waitingForQR: some View {
    VStack(spacing: 12) {
      ProgressView()
      Text("Connecting to WhatsApp daemon…")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func qrCodeView(qr: String) -> some View {
    VStack(spacing: 12) {
      if let image = Self.renderQR(qr) {
        image
          .interpolation(.none)  // crisp pixel edges, no blur
          .resizable()
          .scaledToFit()
          .frame(width: 220, height: 220)
          .accessibilityLabel("WhatsApp pairing QR code")
      } else {
        Text("Failed to render QR code")
          .foregroundStyle(.red)
      }
      // Countdown bar — WhatsApp re-issues the QR every ~20 s, and
      // the daemon pushes the fresh one. This bar resets on every
      // qrUpdate event (we reset qrExpiresAt in handle()).
      ProgressView(value: countdownProgress)
        .progressViewStyle(.linear)
        .frame(width: 220)
        .tint(Platform.whatsapp.accentColor)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var pairingHandshakeView: some View {
    VStack(spacing: 12) {
      ProgressView()
      Text("Phone scanned. Finishing pairing…")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var connectedView: some View {
    VStack(spacing: 12) {
      Image(systemName: "checkmark.circle.fill")
        .font(.system(size: 56))
        .foregroundStyle(Platform.whatsapp.accentColor)
      Text("Connected")
        .font(.title3.weight(.semibold))
      Text("WhatsApp is paired. This window closes in a moment.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .task {
      try? await Task.sleep(nanoseconds: 1_500_000_000)
      isPresented = false
    }
  }

  private var loggedOutView: some View {
    VStack(spacing: 12) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 40))
        .foregroundStyle(.orange)
      Text("Disconnected")
        .font(.title3.weight(.semibold))
      Text("WhatsApp logged this device out remotely (or the daemon hit a logged_out signal). To re-pair, the local session credential must be wiped first.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      Button("Reconnect…") {
        confirmReset = true
      }
      .controlSize(.large)
      .buttonStyle(.borderedProminent)
      .tint(Platform.whatsapp.accentColor)
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func errorView(_ message: String) -> some View {
    VStack(spacing: 12) {
      Image(systemName: "xmark.octagon.fill")
        .font(.system(size: 40))
        .foregroundStyle(.red)
      Text("Couldn't connect")
        .font(.title3.weight(.semibold))
      Text(message)
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      Button("Retry") {
        phase = .subscribing
      }
      .controlSize(.large)
      .buttonStyle(.borderedProminent)
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: - Subscription logic

  private func runSubscription() async {
    let session = WhatsAppQRSession()
    for await event in session.eventStream() {
      // The view may transition into a non-subscription phase (error,
      // connected) — that flips shouldRunSubscription false, the
      // .task(id:) modifier cancels this for-await, and we exit.
      switch event {
      case .subscribed:
        if case .subscribing = phase {
          phase = .awaitingFirstQR
        }
      case .qrUpdate(let qr):
        phase = .awaitingScan(qr: qr)
        // WhatsApp QRs are valid for ~20 s. The daemon will push a
        // fresh one before this expires; we reset the bar on each
        // update.
        qrExpiresAt = Date().addingTimeInterval(20.0)
      case .stateUpdate(let state):
        // The daemon emits "connecting" (Baileys is shaking hands)
        // then "connected" (paired + auth complete). We treat any
        // post-QR state transition that isn't "connecting" as a
        // signal to leave the QR view.
        if state == "connected" {
          phase = .connected
          return
        }
        if state == "connecting" {
          phase = .pairingHandshake
        }
      case .closed:
        if phase != .connected {
          phase = .error("Daemon closed the connection unexpectedly. Check that whatsapp-mcp is running (launchctl list | grep whatsapp-mcp).")
        }
        return
      case .error(let message):
        phase = .error(message)
        return
      }
    }
  }

  private func runUnlinkAndReset() async {
    do {
      try await WhatsAppRPCClient.unlinkAndReset()
      // Daemon clears the sentinel + deletes session.db. Transition
      // back to subscribing — the .task(id:) modifier will fire again.
      phase = .subscribing
    } catch {
      phase = .error("Reconnect failed: \(error.localizedDescription)")
    }
  }

  // MARK: - QR rendering

  /// Convert the daemon-supplied WhatsApp pairing string into a
  /// renderable SwiftUI `Image`. Uses Core Image's
  /// `CIQRCodeGenerator`, rendered at native scale and then upscaled
  /// with `.none` interpolation in the view for crisp pixels.
  private static func renderQR(_ payload: String) -> Image? {
    let ctx = CIContext()
    guard let data = payload.data(using: .utf8),
          let filter = CIFilter(name: "CIQRCodeGenerator")
    else { return nil }
    filter.setValue(data, forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let raw = filter.outputImage else { return nil }
    // Upscale ~10x so the cgImage rasterizes at a usable resolution
    // before SwiftUI's view-side scale.
    let scaled = raw.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
    guard let cg = ctx.createCGImage(scaled, from: scaled.extent) else { return nil }
    let ns = NSImage(cgImage: cg, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    return Image(nsImage: ns)
  }

  /// Linear interpolation from 1.0 (just refreshed) → 0.0 (expired).
  private var countdownProgress: Double {
    let total = 20.0
    let remaining = max(0, qrExpiresAt.timeIntervalSince(now))
    return min(1.0, remaining / total)
  }
}
