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

  @Environment(\.openWindow) private var openWindow
  @Environment(\.dismissWindow) private var dismissWindow

  // Local state while the user is making their picks. We don't write to
  // SettingsStore until "Get Started" — premature writes would surface
  // partial state to the MCP server before the user has confirmed.
  @State private var imessage: Bool = true
  @State private var whatsapp: Bool = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
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
      // Custom Button-as-switch: a SwiftUI Toggle inside a sheet inside
      // MenuBarExtra(.window) leaks its hit-test up to the popover's
      // window-server registration, which treats the click as
      // "outside" and dismisses the popover (and our sheet with it).
      // A Button hit-tests cleanly within the sheet's window.
      SwitchButton(isOn: isOn, enabled: enabled)
    }
    .opacity(enabled ? 1.0 : 0.55)
    .padding(10)
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }

  // MARK: - SwitchButton

  /// Button-rendered switch that mimics a SwiftUI Toggle visually but
  /// hit-tests as a Button. Used in place of Toggle inside sheets
  /// presented from MenuBarExtra(.window) — see comment at call site.
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
      .accessibilityElement()
      .accessibilityValue(isOn ? "on" : "off")
    }
  }

  private func commit() {
    settings.imessageEnabled = imessage
    settings.whatsappEnabled = whatsapp
    settings.firstRunComplete = true

    if whatsapp {
      // Spin up the WhatsApp service so the pairing window finds a
      // live socket. Idempotent — safe even if it's already up.
      whatsappDaemon.start()
      openWindow(id: WindowID.whatsappPairing)
    }

    dismissWindow(id: WindowID.onboarding)
  }
}
