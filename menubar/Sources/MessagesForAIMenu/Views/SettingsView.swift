import SwiftUI
import AppKit

/// Per-transport settings sheet, presented from the popover footer.
/// Adding a transport here is one new section block; the toggle drives
/// SettingsStore + (for WhatsApp) the daemon controller.
struct SettingsView: View {
  @EnvironmentObject var settings: SettingsStore
  @EnvironmentObject var loginItem: LoginItemController
  @EnvironmentObject var whatsappDaemon: WhatsAppDaemonController

  @Binding var isPresented: Bool

  /// When toggled true from the WhatsApp section, parents will present
  /// the existing pairing sheet (sheet-from-sheet is finicky in SwiftUI,
  /// so we close this sheet first and chain).
  @Binding var wantsWhatsAppPairing: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          imessageSection
          whatsappSection
          appSection
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
      Button("Done") { isPresented = false }
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
      VStack(alignment: .leading, spacing: 8) {
        Toggle(isOn: $settings.requireApproval) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Require approval to send")
              .font(.callout)
            Text(settings.requireApproval
                 ? "Agents must stage; only this app can send."
                 : "Agents can send via MCP directly (after staged-age delay).")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .toggleStyle(.switch)
        .disabled(!settings.imessageEnabled)

        infoRow(
          label: "Drafts directory",
          value: "~/.messages-mcp/drafts/"
        )
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
      VStack(alignment: .leading, spacing: 8) {
        daemonStatusRow
        if settings.whatsappEnabled {
          Button {
            // Close this sheet and let DraftListView present the
            // pairing sheet on the same render. (Stacking two sheets
            // in SwiftUI is brittle.)
            wantsWhatsAppPairing = true
            isPresented = false
          } label: {
            HStack(spacing: 6) {
              Image(systemName: Platform.whatsapp.sfSymbol)
              Text("Connect WhatsApp…")
            }
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .disabled(!isDaemonReadyForPairing)
        }
      }
    }
  }

  private var daemonStatusRow: some View {
    HStack(spacing: 8) {
      Circle()
        .fill(daemonStatusColor)
        .frame(width: 8, height: 8)
      Text(daemonStatusLabel)
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

  private var daemonStatusColor: Color {
    switch whatsappDaemon.status {
    case .running: return .green
    case .starting, .backingOff: return .orange
    case .crashLooping: return .red
    case .idle, .stopped: return .gray
    }
  }

  private var daemonStatusLabel: String {
    switch whatsappDaemon.status {
    case .idle: return "Daemon idle"
    case .starting: return "Daemon starting…"
    case .running(let pid): return "Daemon running (pid \(pid))"
    case .backingOff(let nextIn, let count):
      return "Daemon crashed (\(count)×) — retrying in \(Int(nextIn))s"
    case .crashLooping(let count):
      return "Daemon failed to start \(count) times in a row"
    case .stopped: return "Daemon stopped"
    }
  }

  private var isDaemonReadyForPairing: Bool {
    if case .running = whatsappDaemon.status { return true }
    return false
  }

  // MARK: - App-level

  private var appSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("App")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
      Toggle(isOn: Binding(
        get: { loginItem.isEnabled },
        set: { loginItem.setEnabled($0) }
      )) {
        Text("Open at Login")
      }
      .toggleStyle(.switch)
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
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Image(systemName: platform.sfSymbol)
          .foregroundStyle(platform.accentColor)
        Text(title)
          .font(.subheadline.weight(.semibold))
        Spacer()
        Toggle("", isOn: enabledBinding)
          .toggleStyle(.switch)
          .controlSize(.regular)
          .labelsHidden()
      }
      if enabledBinding.wrappedValue {
        content()
      }
    }
    .opacity(enabledBinding.wrappedValue ? 1.0 : 0.6)
    .padding(12)
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
    .clipShape(RoundedRectangle(cornerRadius: 8))
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
}
