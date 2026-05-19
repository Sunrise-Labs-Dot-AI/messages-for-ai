import SwiftUI
import AppKit

/// Per-transport settings sheet, presented from the popover footer.
/// Adding a transport here is one new section block; the toggle drives
/// SettingsStore + (for WhatsApp) the background service controller.
struct SettingsView: View {
  @EnvironmentObject var settings: SettingsStore
  @EnvironmentObject var loginItem: LoginItemController
  @EnvironmentObject var whatsappDaemon: WhatsAppDaemonController

  @Binding var activeSheet: AppSheet?
  @Binding var pendingSheet: AppSheet?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          imessageSection
          whatsappSection
          loginItemRow
        }
        .padding(16)
      }

      Divider()
      footer
    }
    .frame(width: 480, height: 520)
  }

  // MARK: - Header / Footer

  private var header: some View {
    HStack {
      Image(systemName: "gearshape")
        .foregroundStyle(.tint)
      Text("Settings")
        .font(.headline)
      Spacer()
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
  }

  private var footer: some View {
    HStack {
      Spacer()
      Button("Done") { activeSheet = nil }
        .keyboardShortcut(.defaultAction)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
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
        infoRow(label: "Drafts folder", value: "~/.messages-mcp/drafts/")
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
        Button {
          // Chain via the pendingSheet pattern so SwiftUI fully
          // dismisses Settings before presenting Pairing.
          pendingSheet = .whatsappPairing
          activeSheet = nil
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
    switch whatsappDaemon.status {
    case .running: return .green
    case .starting, .backingOff: return .orange
    case .crashLooping: return .red
    case .idle, .stopped: return .gray
    }
  }

  private var connectionLabel: String {
    switch whatsappDaemon.status {
    case .idle:               return "Not connected"
    case .starting:           return "Connecting…"
    case .running:            return isWhatsAppPaired ? "Connected" : "Ready to pair"
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
