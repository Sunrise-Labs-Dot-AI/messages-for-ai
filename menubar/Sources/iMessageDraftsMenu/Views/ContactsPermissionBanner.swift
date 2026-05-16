import SwiftUI

// Shown when Contacts.app Automation permission is missing or failed.
// Under the AppleScript-via-Contacts.app architecture (see comments in
// ContactsExporter.swift for why we don't use CNContactStore), the only
// permission gate is Automation — the same family used for Messages.app
// sending. macOS prompts for it natively on the first NSAppleScript
// call; users approve it once and we never see the banner again.
struct ContactsPermissionBanner: View {
  @EnvironmentObject var exporter: ContactsExporter

  var body: some View {
    if shouldShow {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 6) {
          Image(systemName: "person.crop.circle.badge.exclamationmark")
            .foregroundStyle(.blue)
          Text(headlineText)
            .font(.subheadline.weight(.semibold))
        }
        Text(bodyText)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        HStack(spacing: 8) {
          Button(actionLabel) {
            Task { await primaryAction() }
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
          Button("Recheck") {
            Task { await exporter.exportNow() }
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
        }
      }
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.blue.opacity(0.10))
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .strokeBorder(Color.blue.opacity(0.35), lineWidth: 0.5)
      )
      .clipShape(RoundedRectangle(cornerRadius: 8))
    }
  }

  private var shouldShow: Bool {
    switch exporter.state {
    case .ok: return false
    case .unknown, .automationDenied, .automationNotDetermined, .failed:
      return true
    }
  }

  private var headlineText: String {
    switch exporter.state {
    case .automationDenied: return "Contacts access denied"
    case .automationNotDetermined: return "Allow Contacts access"
    case .unknown: return "Setting up Contacts…"
    case .failed: return "Couldn't read Contacts"
    case .ok: return ""
    }
  }

  private var bodyText: String {
    switch exporter.state {
    case .unknown, .automationNotDetermined:
      return "iMessage Drafts reads your Contacts via Contacts.app — the same source Messages.app uses, including iCloud contacts. Click 'Allow…' and macOS will ask you to approve access to Contacts.app."
    case .automationDenied:
      return "Open System Settings → Privacy & Security → Automation, find iMessage Drafts, and turn on Contacts. Then click Recheck."
    case .failed(let msg):
      return "AppleScript error: \(msg). Click Recheck to try again."
    case .ok:
      return ""
    }
  }

  private var actionLabel: String {
    switch exporter.state {
    case .automationDenied, .failed: return "Open Settings"
    default: return "Allow…"
    }
  }

  private func primaryAction() async {
    switch exporter.state {
    case .automationDenied, .failed:
      ContactsExporter.openAutomationSettings()
    default:
      await exporter.requestAccessAndExport()
    }
  }
}
