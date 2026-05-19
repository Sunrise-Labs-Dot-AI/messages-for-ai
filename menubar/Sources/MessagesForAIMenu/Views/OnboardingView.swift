import SwiftUI

/// First-run wizard. Presented as a `.sheet` over the popover when the
/// SettingsStore's `firstRunComplete` flag is false. The user picks
/// which transports they want enabled; clicking "Get Started" writes
/// the choices into `~/.messages-mcp/settings.json`, spawns any
/// enabled daemons, and (if WhatsApp was checked) chains directly into
/// the pairing sheet.
///
/// Triggered from DraftListView (the only popover-resident view).
struct OnboardingView: View {
  @EnvironmentObject var settings: SettingsStore
  @EnvironmentObject var whatsappDaemon: WhatsAppDaemonController

  /// Bound to the sheet presenter on DraftListView. We flip it to false
  /// after writing settings; the parent's `onChange` then decides
  /// whether to chain into the pairing sheet.
  @Binding var isPresented: Bool

  /// True if the user wants the pairing sheet to appear right after
  /// onboarding closes. Parent reads this via `onChange(of:)` and
  /// presents WhatsAppPairingView.
  @Binding var wantsWhatsAppPairing: Bool

  // Local state while the user is making their picks. We don't write to
  // SettingsStore until "Get Started" — premature writes would surface
  // partial state to the MCP server before the user has confirmed.
  @State private var imessage: Bool = true
  @State private var whatsapp: Bool = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      header

      Divider()

      Text("Pick the messaging services you want Claude to draft for. You can change these any time in Settings.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      VStack(alignment: .leading, spacing: 10) {
        transportRow(
          platform: .imessage,
          title: "iMessage",
          subtitle: "Send via Messages.app. Requires Full Disk Access for thread context.",
          isOn: $imessage,
          enabled: true,
          comingSoon: false
        )
        transportRow(
          platform: .whatsapp,
          title: "WhatsApp",
          subtitle: "Pair via QR scan. Uses an unofficial Baileys client — review WhatsApp's ToS first.",
          isOn: $whatsapp,
          enabled: true,
          comingSoon: false
        )
      }

      Spacer(minLength: 8)

      HStack {
        Spacer()
        Button("Get Started") {
          commit()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!imessage && !whatsapp)
      }
    }
    .padding(20)
    .frame(width: 460)
  }

  private var header: some View {
    HStack(spacing: 10) {
      Image(systemName: "message.badge")
        .font(.system(size: 28))
        .foregroundStyle(.tint)
      VStack(alignment: .leading, spacing: 2) {
        Text("Welcome to Messages for AI")
          .font(.title3.weight(.semibold))
        Text("AI proposes, you approve.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
    }
  }

  private func transportRow(
    platform: Platform?,
    title: String,
    subtitle: String,
    isOn: Binding<Bool>,
    enabled: Bool,
    comingSoon: Bool
  ) -> some View {
    HStack(alignment: .top, spacing: 12) {
      if let platform = platform {
        Image(systemName: platform.sfSymbol)
          .font(.system(size: 18))
          .foregroundStyle(platform.accentColor)
          .frame(width: 28)
      } else {
        Image(systemName: "lock")
          .font(.system(size: 18))
          .foregroundStyle(.tertiary)
          .frame(width: 28)
      }
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(title).font(.callout.weight(.medium))
          if comingSoon {
            Text("Coming v0.4")
              .font(.caption2)
              .padding(.horizontal, 6)
              .padding(.vertical, 1)
              .background(Color(nsColor: .controlBackgroundColor))
              .clipShape(Capsule())
              .foregroundStyle(.secondary)
          }
        }
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer()
      Toggle("", isOn: isOn)
        .toggleStyle(.switch)
        .controlSize(.regular)
        .disabled(!enabled)
        .labelsHidden()
    }
    .opacity(enabled ? 1.0 : 0.55)
    .padding(10)
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }

  private func commit() {
    settings.imessageEnabled = imessage
    settings.whatsappEnabled = whatsapp
    settings.firstRunComplete = true

    if whatsapp {
      // Kick the daemon up so the pairing sheet finds a live socket.
      // Idempotent — safe to call even if the daemon is already up.
      whatsappDaemon.start()
      wantsWhatsAppPairing = true
    }

    isPresented = false
  }
}
