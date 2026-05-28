import SwiftUI
import AppKit

/// Per-transport settings sheet, presented from the popover footer.
/// Adding a transport here is one new section block; the toggle drives
/// SettingsStore + (for WhatsApp) the background service controller.
struct SettingsView: View {
  @EnvironmentObject var settings: SettingsStore
  @EnvironmentObject var loginItem: LoginItemController
  @EnvironmentObject var whatsappDaemon: WhatsAppDaemonController
  @EnvironmentObject var imessageDaemon: IMessageDaemonController

  @Environment(\.openWindow) private var openWindow
  // Ungated: the Status pane reports the real last-seen call time even when
  // it's older than the walkthrough's 10-minute freshness window, so prior
  // history (which persists in ~/.messages-mcp/ across reinstalls) doesn't
  // read as "never."
  @StateObject private var invocations = LastInvocationStore(applyStalenessGate: false)

  private let checks = HealthChecks()

  var body: some View {
    // The native macOS title bar (set in App.swift as "Messages for AI
    // Settings") is the window's chrome — no in-content header needed.
    // The Window already provides traffic-light controls + drag.
    //
    // Top padding is larger than the other sides so the iMessage section
    // header doesn't crowd the title bar. The Window frame is set in
    // App.swift; don't redeclare it here (conflicting frames let the
    // ScrollView creep up under the title bar in 14.x).
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        imessageSection
        whatsappSection
        loginItemRow
        statusSection
        versionFooter
      }
      .padding(.horizontal, 16)
      .padding(.top, 24)
      .padding(.bottom, 16)
    }
  }

  // MARK: - iMessage

  private var imessageSection: some View {
    transportCard(
      platform: .imessage,
      title: "iMessage",
      enabledBinding: $settings.imessageEnabled
    ) {
      VStack(alignment: .leading, spacing: 10) {
        imessageDaemonRow
        labeledSwitchRow(
          title: "Require approval to send",
          subtitle: settings.requireApproval
            ? "Claude must stage drafts. Only this app can send."
            : "Claude can send via MCP directly (after a brief delay).",
          isOn: $settings.requireApproval,
          enabled: settings.imessageEnabled
        )
        // Drafts-folder path was removed: it's only the iMessage path
        // (WhatsApp uses ~/.whatsapp-mcp/drafts), making it misleading
        // when shown only under the iMessage section. The dir is also
        // a place users could corrupt the staging state by editing
        // JSON files — surfacing it as text invites that. If a future
        // "Open drafts in Finder" button is added, it should be a
        // proper button gated behind a power-user toggle.
      }
    }
  }

  /// Compact status row for the chat.db reader daemon. The daemon is what
  /// actually holds Full Disk Access (it's launched by this menu-bar app);
  /// the Claude-launched MCP is a thin client to it. No remote connection
  /// like WhatsApp — just process liveness.
  private var imessageDaemonRow: some View {
    HStack(spacing: 8) {
      Circle()
        .fill(imessageDaemonColor)
        .frame(width: 8, height: 8)
      Text(imessageDaemonLabel)
        .font(.caption)
        .foregroundStyle(.secondary)
      Spacer()
      if case .crashLooping = imessageDaemon.status {
        Button("Restart") { imessageDaemon.start() }
          .buttonStyle(.bordered)
          .controlSize(.mini)
      }
    }
  }

  private var imessageDaemonColor: Color {
    switch imessageDaemon.status {
    case .running: return .green
    case .starting, .backingOff: return .orange
    case .crashLooping: return .red
    case .idle, .stopped: return .gray
    }
  }

  private var imessageDaemonLabel: String {
    switch imessageDaemon.status {
    case .idle: return "Reader service: idle"
    case .starting: return "Reader service: starting…"
    case .running: return "Reader service: running"
    case .backingOff(let s, _): return "Reader service: restarting in \(Int(s))s"
    case .crashLooping: return "Reader service: couldn’t start — tap Restart"
    case .stopped: return "Reader service: stopped"
    }
  }

  // MARK: - WhatsApp

  private var whatsappSection: some View {
    transportCard(
      platform: .whatsapp,
      title: "WhatsApp",
      enabledBinding: Binding(
        get: { settings.whatsappEnabled },
        set: { newValue in
          settings.whatsappEnabled = newValue
          if newValue {
            whatsappDaemon.start()
          } else {
            Task { await whatsappDaemon.stop() }
          }
        }
      )
    ) {
      VStack(alignment: .leading, spacing: 10) {
        connectionRow
        labeledSwitchRow(
          title: "Require approval to send",
          subtitle: settings.whatsappRequireApproval
            ? "Claude stages drafts. Hold-to-fire in this app sends."
            : "Claude can send via MCP directly (rate-limited).",
          isOn: $settings.whatsappRequireApproval,
          enabled: settings.whatsappEnabled
        )
        // Only show a pairing action when one is actually needed:
        //  - "Connect WhatsApp…" if the user has never paired
        //  - "Reconnect WhatsApp…" if the daemon reports logged_out
        // When WhatsApp is healthy (paired + Baileys connected/connecting/
        // reconnecting) the button is clutter, so hide it. Power-user
        // re-pair-without-being-logged-out path is deferred to a kebab
        // menu in a future polish round.
        if shouldShowPairingButton {
          Button {
            openWindow(id: WindowID.whatsappPairing)
          } label: {
            HStack(spacing: 6) {
              Image(systemName: Platform.whatsapp.sfSymbol)
              Text(isWhatsAppPaired ? "Reconnect WhatsApp…" : "Connect WhatsApp…")
            }
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
        }
      }
    }
  }

  /// True when the pairing action is meaningful — either first-time
  /// pair (no session) or recovery from a remote unlink (daemon reports
  /// logged_out). Healthy paired sessions hide the button.
  private var shouldShowPairingButton: Bool {
    if !isWhatsAppPaired { return true }
    if whatsappDaemon.baileysState == "logged_out" { return true }
    return false
  }

  /// Single-line status row — replaces the previous "Daemon running
  /// (pid 12345)" jargon with user-facing connection state.
  private var connectionRow: some View {
    HStack(spacing: 8) {
      Circle()
        .fill(connectionColor)
        .frame(width: 8, height: 8)
      Text(connectionLabel)
        .font(.caption)
        .foregroundStyle(.secondary)
      Spacer()
      if case .crashLooping = whatsappDaemon.status {
        Button("Restart") { whatsappDaemon.start() }
          .buttonStyle(.bordered)
          .controlSize(.mini)
      }
    }
  }

  private var connectionColor: Color {
    // When the daemon's up AND we've polled its Baileys state, prefer
    // the finer-grained color. Otherwise fall back to coarse process-
    // level signals.
    if case .running = whatsappDaemon.status, let bs = whatsappDaemon.baileysState {
      switch bs {
      case "connected":               return .green
      case "connecting", "reconnecting": return .orange
      case "logged_out":              return .red
      default:                        return .gray
      }
    }
    switch whatsappDaemon.status {
    case .running: return .green
    case .starting, .backingOff: return .orange
    case .crashLooping: return .red
    case .idle, .stopped: return .gray
    }
  }

  private var connectionLabel: String {
    // When we have a live Baileys state, that's the source of truth.
    // The daemon process being up doesn't mean WhatsApp is reachable:
    // it can be reconnecting after a network blip or waiting in
    // logged_out after a remote unlink.
    if case .running = whatsappDaemon.status, let bs = whatsappDaemon.baileysState {
      switch bs {
      case "connecting":    return isWhatsAppPaired ? "Connecting…" : "Waiting to pair…"
      case "connected":     return "Connected"
      case "reconnecting":  return "Reconnecting…"
      case "logged_out":    return "Logged out — Reconnect WhatsApp"
      default:              return bs
      }
    }
    switch whatsappDaemon.status {
    case .idle:               return "Not connected"
    case .starting:           return "Starting…"
    case .running:            return "Connecting…"  // no Baileys state yet — first poll hasn't landed
    case .backingOff(let s, _): return "Reconnecting in \(Int(s))s"
    case .crashLooping:       return "Couldn't connect"
    case .stopped:            return "Turned off"
    }
  }

  /// Heuristic: pairing has happened if the Baileys session file exists.
  /// The file is created on first scan and persists across daemon
  /// restarts.
  private var isWhatsAppPaired: Bool {
    FileManager.default.fileExists(atPath:
      FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".whatsapp-mcp")
        .appendingPathComponent("session.db")
        .path
    )
  }

  // MARK: - App-level

  /// Single-line login-item toggle in its own card — visually parallel
  /// to the transport cards but without the on/off header.
  private var loginItemRow: some View {
    VStack(alignment: .leading, spacing: 8) {
      labeledSwitchRow(
        title: "Open at Login",
        subtitle: nil,
        isOn: Binding(
          get: { loginItem.isEnabled },
          set: { loginItem.setEnabled($0) }
        ),
        enabled: true
      )
      if let warning = loginItem.statusDescription {
        Text(warning)
          .font(.caption2)
          .foregroundStyle(.orange)
      }
    }
    .padding(12)
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }

  // MARK: - Status

  /// On-demand diagnostics surface — same HealthChecks primitives the
  /// SetupWalkthroughView uses, plus the latest witness timestamp per
  /// transport so the user can answer "is Claude actually using this?"
  /// at a glance. "Re-run setup walkthrough" is the recovery affordance
  /// when something has broken (e.g. Claude Desktop was re-installed
  /// without the MCP config).
  private var statusSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Status")
          .font(.headline)
        Spacer()
      }

      let imessageBinPath = HealthChecks.defaultBundleBinaryPrefix + "imessage-drafts-mcp"
      let imessageDaemonBinPath = HealthChecks.defaultBundleBinaryPrefix + "imessage-drafts-daemon"
      let whatsappBinPath = HealthChecks.defaultBundleBinaryPrefix + "whatsapp-drafts-mcp"
      let daemonBinPath = HealthChecks.defaultBundleBinaryPrefix + "whatsapp-drafts-daemon"
      let configState = checks.claudeDesktopConfigState()

      statusRow(
        label: "iMessage MCP binary",
        passing: checks.binaryExists(at: imessageBinPath)
          && checks.codesignIdentifier(of: imessageBinPath) == HealthChecks.expectedSigningIdentifier
      )
      // The daemon binary — not the thin MCP client — is what reads chat.db
      // post-#17. Check it here too, in parity with the WhatsApp daemon row
      // below and the setup walkthrough, so this pane can't read all-green
      // while the reader binary is missing/unsigned.
      statusRow(
        label: "iMessage daemon binary",
        passing: checks.binaryExists(at: imessageDaemonBinPath)
          && checks.codesignIdentifier(of: imessageDaemonBinPath) == HealthChecks.expectedSigningIdentifier
      )
      if settings.whatsappEnabled {
        statusRow(
          label: "WhatsApp MCP binary",
          passing: checks.binaryExists(at: whatsappBinPath)
            && checks.codesignIdentifier(of: whatsappBinPath) == HealthChecks.expectedSigningIdentifier
        )
        statusRow(
          label: "WhatsApp daemon binary",
          passing: checks.binaryExists(at: daemonBinPath)
            && checks.codesignIdentifier(of: daemonBinPath) == HealthChecks.expectedSigningIdentifier
        )
      }

      switch configState {
      case .found:
        statusRow(label: "Claude Desktop config references this app", passing: true)
      case .notFound:
        statusRow(label: "Claude Desktop config doesn't reference this app", passing: false)
      case .fileAbsent:
        statusRow(label: "Claude Desktop not detected", passing: nil)
      case .parseError:
        statusRow(label: "Claude Desktop config can't be parsed", passing: false)
      }

      lastInvocationRow(label: "Last iMessage call from Claude", record: invocations.imessage)
      if settings.imessageEnabled {
        // chat.db access as seen by the reader DAEMON. Post-refactor the MCP's
        // witness reports the daemon's status (the MCP no longer touches
        // chat.db itself). "denied" means the Messages for AI app lacks Full
        // Disk Access — Claude does NOT need FDA (issue #17 + daemon refactor).
        clientFdaRow(record: invocations.imessage)
      }
      if settings.whatsappEnabled {
        lastInvocationRow(label: "Last WhatsApp call from Claude", record: invocations.whatsapp)
      }

      HStack(spacing: 10) {
        Button("Re-run setup walkthrough") {
          openWindow(id: WindowID.setupWalkthrough)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        Button("Reveal logs") {
          let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".messages-mcp/logs")
          NSWorkspace.shared.open(url)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        Spacer()
      }
      .padding(.top, 4)
    }
    .padding(14)
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
    .clipShape(RoundedRectangle(cornerRadius: 10))
  }

  private func statusRow(label: String, passing: Bool?) -> some View {
    HStack(spacing: 8) {
      let (symbol, color): (String, Color) = {
        switch passing {
        case true?: return ("checkmark.circle.fill", .green)
        case false?: return ("xmark.circle.fill", .red)
        case nil: return ("circle.dotted", .secondary)
        }
      }()
      Image(systemName: symbol)
        .foregroundStyle(color)
        .accessibilityHidden(true)
      Text(label).font(.caption)
      Spacer()
    }
    // Combine icon + label so VoiceOver announces the row as a single
    // sentence instead of reading the SF Symbol name separately.
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(label), \(Self.statusWord(for: passing))")
  }

  private func lastInvocationRow(label: String, record: WitnessRecord?) -> some View {
    HStack(spacing: 8) {
      Image(systemName: record == nil ? "circle.dotted" : "clock")
        .foregroundStyle(record == nil ? Color.secondary : Color.green)
        .accessibilityHidden(true)
      Text(label).font(.caption)
      Spacer()
      Text(record.map { Self.relative($0.ts) } ?? "no record yet")
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(label): \(record.map { Self.relative($0.ts) } ?? "no record yet")")
  }

  /// Surfaces the Claude-launched iMessage MCP's own chat.db access, read from
  /// the witness record it writes (issue #17). nil record / nil access → we
  /// haven't heard from a witness that reports it yet.
  private func clientFdaRow(record: WitnessRecord?) -> some View {
    let access = record?.chatDbAccess
    let (passing, value): (Bool?, String) = {
      switch access {
      case .ok: return (true, "granted")
      case .permissionDenied: return (false, "denied — enable ‘Messages for AI’ in Full Disk Access")
      case .notFound: return (nil, "no Messages DB")
      case .unknown: return (nil, "unknown")
      case .none: return (nil, "no record yet")
      }
    }()
    let symbol = passing == true ? "checkmark.circle.fill"
      : (passing == false ? "xmark.circle.fill" : "circle.dotted")
    let color: Color = passing == true ? .green : (passing == false ? .red : .secondary)
    return HStack(spacing: 8) {
      Image(systemName: symbol)
        .foregroundStyle(color)
        .accessibilityHidden(true)
      Text("iMessage reader Full Disk Access").font(.caption)
      Spacer()
      Text(value)
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.trailing)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("iMessage reader Full Disk Access: \(value)")
  }

  /// Status word used inside combined accessibility labels.
  private static func statusWord(for value: Bool?) -> String {
    switch value {
    case true?: return "passed"
    case false?: return "failed"
    case nil: return "not yet checked"
    }
  }

  private static func relative(_ date: Date) -> String {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    return f.localizedString(for: date, relativeTo: Date())
  }

  // MARK: - Card scaffold

  @ViewBuilder
  private func transportCard<Content: View>(
    platform: Platform,
    title: String,
    enabledBinding: Binding<Bool>,
    @ViewBuilder _ content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 10) {
        Image(systemName: platform.sfSymbol)
          .foregroundStyle(platform.accentColor)
        Text(title)
          .font(.headline)
        Spacer()
        SwitchButton(isOn: enabledBinding, enabled: true)
      }
      if enabledBinding.wrappedValue {
        content()
      }
    }
    .opacity(enabledBinding.wrappedValue ? 1.0 : 0.6)
    .padding(14)
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
    .clipShape(RoundedRectangle(cornerRadius: 10))
  }

  // MARK: - Row scaffolds

  /// Label (+ optional subtitle) on the left, a SwitchButton on the
  /// right. Switches across rows line up because the SwitchButton has
  /// a fixed footprint and the HStack uses Spacer().
  private func labeledSwitchRow(
    title: String,
    subtitle: String?,
    isOn: Binding<Bool>,
    enabled: Bool
  ) -> some View {
    HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.callout)
        if let subtitle = subtitle {
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer()
      SwitchButton(isOn: isOn, enabled: enabled)
    }
  }

  // MARK: - Version footer

  // Bottom-of-page build stamp so a dev install (or a release) can be
  // identified at a glance. Values come from the bundle Info.plist:
  // CFBundleShortVersionString + CFBundleVersion are written by
  // dev-install.sh (git short SHA, "-dirty" if the tree had uncommitted
  // changes) / build-release.sh (release version). MFABuildTime is the
  // dev-install build timestamp. Falls back gracefully when run outside a
  // packaged .app (e.g. `swift run` / tests), where the keys are absent.
  private var versionFooter: some View {
    VStack(spacing: 2) {
      Divider().padding(.bottom, 2)
      Text("Messages for AI \(Self.appVersion)")
        .font(.caption2)
        .foregroundStyle(.secondary)
      Text(Self.buildStamp)
        .font(.caption2.monospaced())
        .foregroundStyle(.tertiary)
        .textSelection(.enabled)
    }
    .frame(maxWidth: .infinity)
    .padding(.top, 2)
  }

  static var appVersion: String {
    (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
  }

  static var buildStamp: String {
    let sha = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "—"
    if let t = Bundle.main.object(forInfoDictionaryKey: "MFABuildTime") as? String, !t.isEmpty {
      return "build \(sha) · \(t)"
    }
    return "build \(sha)"
  }

  private func infoRow(label: String, value: String) -> some View {
    HStack {
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
      Spacer()
      Text(value)
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }
  }

  // MARK: - Button-as-switch

  /// Reused from OnboardingView's pattern — Toggle hit-tests bleed
  /// through MenuBarExtra(.window) sheet boundaries and dismiss the
  /// popover. A Button keeps the hit-test inside the sheet's window.
  private struct SwitchButton: View {
    @Binding var isOn: Bool
    let enabled: Bool

    var body: some View {
      Button {
        isOn.toggle()
      } label: {
        ZStack(alignment: isOn ? .trailing : .leading) {
          RoundedRectangle(cornerRadius: 11)
            .fill(isOn ? Color.accentColor : Color(nsColor: .quaternaryLabelColor))
            .frame(width: 36, height: 22)
          Circle()
            .fill(.white)
            .frame(width: 18, height: 18)
            .padding(2)
            .shadow(radius: 1, y: 0.5)
        }
      }
      .buttonStyle(.plain)
      .disabled(!enabled)
      .animation(.easeInOut(duration: 0.15), value: isOn)
    }
  }
}
