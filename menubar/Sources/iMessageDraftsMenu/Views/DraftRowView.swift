import SwiftUI

struct DraftRowView: View {
  let draft: Draft
  @EnvironmentObject var store: DraftStore
  @State private var sending = false
  @State private var lastError: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      // ─── Header: recipient + when ──────────────────────────────────
      HStack(alignment: .firstTextBaseline) {
        Text(draft.to_handle)
          .font(.system(.subheadline, design: .rounded).weight(.semibold))
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer()
        Text(relativeStagedAt)
          .font(.caption)
          .foregroundStyle(.secondary)
          .help(absoluteStagedAt) // hover for full timestamp
      }

      // ─── Body ───────────────────────────────────────────────────────
      Text(draft.body)
        .font(.body)
        .textSelection(.enabled)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
          RoundedRectangle(cornerRadius: 6)
            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )

      // ─── Provenance: source label + absolute time ─────────────────
      // Always shown so the reviewer has full context at a glance.
      VStack(alignment: .leading, spacing: 2) {
        if let source = draft.source, !source.isEmpty {
          HStack(spacing: 4) {
            Image(systemName: "person.crop.circle.dashed")
              .font(.caption2)
              .foregroundStyle(.tertiary)
            Text(source)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.tail)
          }
        }
        HStack(spacing: 4) {
          Image(systemName: "clock")
            .font(.caption2)
            .foregroundStyle(.tertiary)
          Text("Staged \(absoluteStagedAt)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      if let lastError {
        Text(lastError)
          .font(.caption)
          .foregroundStyle(.red)
      }

      // ─── Actions ────────────────────────────────────────────────────
      HStack(spacing: 8) {
        Button(action: { Task { await send() } }) {
          if sending {
            ProgressView().controlSize(.small).frame(width: 50)
          } else {
            Text("Send").frame(minWidth: 50)
          }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .disabled(sending)
        .keyboardShortcut(.return, modifiers: [.command])

        Button("Discard") {
          do { try store.discard(id: draft.id) }
          catch { lastError = "discard failed: \(error.localizedDescription)" }
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .disabled(sending)

        Spacer()

        if let service = draft.send_service {
          Label(service, systemImage: service == "iMessage" ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .padding(12)
    .background(Color(nsColor: .controlBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 10))
  }

  // MARK: - Helpers

  private var relativeStagedAt: String {
    guard let date = draft.stagedDate else { return draft.staged_at }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
  }

  // "Today 2:35 PM" / "Yesterday 4:12 PM" / "May 12 at 9:01 AM"
  // Localized; respects the user's clock format preference.
  private var absoluteStagedAt: String {
    guard let date = draft.stagedDate else { return draft.staged_at }
    let formatter = DateFormatter()
    formatter.doesRelativeDateFormatting = true
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: date)
  }

  private func send() async {
    sending = true
    lastError = nil
    let result = await DraftSender.send(toHandle: draft.to_handle, body: draft.body)
    if result.ok, let service = result.service {
      do {
        try store.markSent(id: draft.id, sentAt: Date(), service: service)
      } catch {
        lastError = "sent ok but failed to update draft file: \(error.localizedDescription)"
      }
    } else {
      lastError = result.error ?? "unknown error"
    }
    sending = false
  }
}
