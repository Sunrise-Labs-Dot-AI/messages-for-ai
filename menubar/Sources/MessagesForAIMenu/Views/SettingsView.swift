import SwiftUI
import AppKit

/// Per-transport settings sheet, presented from the popover footer.
/// Adding a transport here is one new section block; the toggle drives
/// SettingsStore + (for WhatsApp) the background service controller.
struct SettingsView: View {
  @EnvironmentObject var settings: SettingsStore
  @EnvironmentObject var loginItem: LoginItemController
  @EnvironmentObject var whatsappDaemon: WhatsAppDaemonController

  @Environment(\.openWindow) private var openWindow
  @StateObject private var invocations = LastInvocationStore()

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
      let whatsappBinPath = HealthChecks.defaultBundleBinaryPrefix + "whatsapp-drafts-mcp"
      let daemonBinPath = HealthChecks.defaultBundleBinaryPrefix + "whatsapp-drafts-daemon"
      let configState = checks.claudeDesktopConfigState()

      statusRow(
        label: "iMessage MCP binary",
        passing: checks.binaryExists(at: imessageBinPath)
          && checks.codesignIdentifier(of: imessageBinPath) == HealthChecks.expectedSigningIdentifier
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
        case true: return ("checkmark.circle.fill", .green)
        case false: return ("xmark.circle.fill", .red)
        case nil: return ("circle.dotted", .secondary)
        }
      }()
      Image(systemName: symbol).foregroundStyle(color)
      Text(label).font(.caption)
      Spacer()
    }
  }

  private func lastInvocationRow(label: String, record: WitnessRecord?) -> some View {
    HStack(spacing: 8) {
      Image(systemName: record == nil ? "circle.dotted" : "clock")
        .foregroundStyle(record == nil ? Color.secondary : Color.green)
      Text(label).font(.caption)
      Spacer()
      Text(record.map { Self.relative($0.ts) } ?? "never")
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
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
