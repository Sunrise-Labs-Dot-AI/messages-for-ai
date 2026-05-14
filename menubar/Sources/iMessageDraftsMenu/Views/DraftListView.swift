import SwiftUI
import AppKit

struct DraftListView: View {
  @EnvironmentObject var store: DraftStore

  private var pending: [Draft] { store.drafts.filter { !$0.isSent } }
  private var recentlySent: [Draft] {
    let oneHourAgo = Date().addingTimeInterval(-3600)
    return store.drafts.filter { d in
      guard let sent = d.sentDate else { return false }
      return sent > oneHourAgo
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header

      Divider()

      if let err = store.lastRefreshError {
        Text("⚠️ \(err)")
          .font(.caption)
          .foregroundStyle(.red)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
      }

      ScrollView {
        VStack(spacing: 8) {
          if pending.isEmpty {
            emptyState
          } else {
            ForEach(pending) { draft in
              DraftRowView(draft: draft)
            }
          }

          if !recentlySent.isEmpty {
            recentlySentSection
          }
        }
        .padding(12)
      }
      .frame(maxHeight: 480)

      Divider()
      footer
    }
    .frame(width: 380)
  }

  // MARK: - Sections

  private var header: some View {
    HStack {
      Image(systemName: "message.badge")
        .foregroundStyle(.tint)
      Text("iMessage Drafts")
        .font(.headline)
      Spacer()
      Text(pending.isEmpty ? "—" : "\(pending.count) pending")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
  }

  private var emptyState: some View {
    VStack(spacing: 6) {
      Image(systemName: "tray")
        .font(.system(size: 28))
        .foregroundStyle(.tertiary)
      Text("No pending drafts")
        .font(.callout)
        .foregroundStyle(.secondary)
      Text("Drafts staged by Claude will appear here.")
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 24)
  }

  private var recentlySentSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Recently sent")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.top, 4)
      ForEach(recentlySent) { draft in
        HStack(spacing: 8) {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.green)
          VStack(alignment: .leading, spacing: 2) {
            Text(draft.to_handle)
              .font(.caption.weight(.medium))
            Text(draft.body)
              .font(.caption)
              .lineLimit(1)
              .foregroundStyle(.secondary)
          }
          Spacer()
          if let sent = draft.sentDate {
            Text(relative(sent))
              .font(.caption2)
              .foregroundStyle(.tertiary)
          }
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
      }
    }
  }

  private var footer: some View {
    HStack {
      Button("Refresh") { store.refresh() }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)

      Spacer()

      Button("Quit") {
        NSApplication.shared.terminate(nil)
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .keyboardShortcut("q", modifiers: [.command])
    }
    .font(.caption)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  private func relative(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
  }
}
