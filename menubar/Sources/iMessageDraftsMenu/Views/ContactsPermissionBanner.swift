import SwiftUI
import Contacts

// Sister banner to FDABanner, shown when the menu bar app's Contacts
// authorization is not `.authorized`. The product reasoning:
// CNContactStore is the user-facing path for contact name resolution —
// it sees iCloud-synced data and pops a native consent dialog. When
// it's denied, we want the user to know the menu bar app is the
// gating dependency (not Full Disk Access on the MCP binary), and we
// want to make granting one click away.
//
// Behavior by status:
//   - .notDetermined → "Allow Contacts access" button calls
//     ContactsExporter.requestAccessAndExport() which fires the native
//     "iMessage Drafts would like to access your Contacts" dialog.
//   - .denied / .restricted → "Open Contacts Settings" button deep-links
//     to System Settings → Privacy & Security → Contacts where the
//     user can flip the toggle.
//   - .authorized → banner renders nothing.
struct ContactsPermissionBanner: View {
  @EnvironmentObject var exporter: ContactsExporter

  var body: some View {
    if exporter.authorizationStatus != .authorized {
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
          if exporter.authorizationStatus == .denied || exporter.authorizationStatus == .restricted {
            Button("Recheck") {
              Task { await exporter.exportNow() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
          }
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

  // MARK: - Status-driven copy

  private var headlineText: String {
    switch exporter.authorizationStatus {
    case .notDetermined: return "Allow Contacts access"
    case .denied:        return "Contacts access denied"
    case .restricted:    return "Contacts access restricted by policy"
    default:             return "Contacts access unavailable"
    }
  }

  private var bodyText: String {
    switch exporter.authorizationStatus {
    case .notDetermined:
      return "iMessage Drafts uses Contacts to resolve recipient names. This is the same data Messages.app sees, including iCloud-synced contacts."
    case .denied:
      return "Open System Settings → Privacy & Security → Contacts and turn on iMessage Drafts. Then click Recheck."
    case .restricted:
      return "Your organization's MDM policy disallows Contacts access. The MCP will fall back to AddressBook SQLite, which requires Full Disk Access on the imessage-mcp binary and may miss iCloud-only contacts."
    default:
      return "An unexpected Contacts authorization status was reported."
    }
  }

  private var actionLabel: String {
    switch exporter.authorizationStatus {
    case .notDetermined: return "Allow…"
    default:             return "Open Settings"
    }
  }

  private func primaryAction() async {
    switch exporter.authorizationStatus {
    case .notDetermined:
      await exporter.requestAccessAndExport()
    default:
      ContactsExporter.openContactsSettings()
    }
  }
}
