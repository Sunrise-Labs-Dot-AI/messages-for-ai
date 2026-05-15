import SwiftUI
import AppKit

struct DraftListView: View {
  @EnvironmentObject var store: DraftStore
  @EnvironmentObject var loginItem: LoginItemController
  @EnvironmentObject var settings: SettingsStore

  private var pending: [Draft] { store.drafts.filter { !$0.isSent } }
  // Screen-aware popover height. `visibleFrame` excludes the menu bar
  // and dock so we don't propose a value the popover can't actually
  // render. Default is a comfortable ~70% of available; "Tall" mode
  // bumps to ~95% (just shy of full available height). Floor of 600
  // keeps small MacBook Air screens feeling generous rather than
  // strictly proportional.
  private var maxPopoverHeight: CGFloat {
    let screenH = NSScreen.main?.visibleFrame.height ?? 900
    let factor: CGFloat = settings.tallPopover ? 0.95 : 0.70
    return max(600, screenH * factor)
  }

  private var recentlySent: [Draft] {
    // 24-hour visible window for sent drafts. The on-disk draft JSON and
    // the ~/.imessage-mcp/send-audit.log keep forever — this is just the
    // popover's confirmation-breadcrumb view.
    let cutoff = Date().addingTimeInterval(-86_400)
    return store.drafts.filter { d in
      guard let sent = d.sentDate else { return false }
      return sent > cutoff
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

      // ScrollView inside MenuBarExtra(.window) collapses to ~0 height
      // when its parent has no concrete height to grant — there's no
      // implicit minimum, so it'd render an empty band between header
      // and footer even with pending rows present. We give it an
      // explicit height range here and rely on macOS to cap by screen
      // height if needed.
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
        .frame(maxWidth: .infinity)
      }
      // Screen-aware vertical sizing. minHeight keeps the empty case
      // from collapsing to a sliver; maxHeight scales to the user's
      // current screen so a 13" MacBook Air (~800pt visible) and a
      // 5K iMac (~1500pt visible) both feel right. The "Tall layout"
      // toggle in the footer lets the user override default → fill.
      .frame(minHeight: 360, maxHeight: maxPopoverHeight)

      Divider()
      footer
    }
    .frame(width: 420)
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
    VStack(spacing: 6) {
      // Settings rows.
      HStack(spacing: 8) {
        Toggle(isOn: $settings.requireApproval) {
          VStack(alignment: .leading, spacing: 1) {
            Text("Require draft approval to send")
              .font(.caption)
            Text(settings.requireApproval
                 ? "Agents must stage; only this app can send."
                 : "Agents can send via MCP directly (after staged-age delay).")
              .font(.caption2)
              .foregroundStyle(.tertiary)
          }
        }
        .toggleStyle(.switch)
        .controlSize(.mini)

        Spacer()
      }

      HStack(spacing: 8) {
        Toggle(isOn: Binding(
          get: { loginItem.isEnabled },
          set: { loginItem.setEnabled($0) }
        )) {
          Text("Open at Login")
            .font(.caption)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)

        Spacer()
      }

      HStack(spacing: 8) {
        Toggle(isOn: $settings.tallPopover) {
          Text("Tall layout")
            .font(.caption)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .help("Fills ~95% of screen height instead of the default ~70%.")

        Spacer()
      }

      if let warning = loginItem.statusDescription {
        Text(warning)
          .font(.caption2)
          .foregroundStyle(.orange)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      if let err = loginItem.lastError {
        Text(err)
          .font(.caption2)
          .foregroundStyle(.red)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      // Action row.
      HStack(spacing: 12) {
        Button("Refresh") { store.refresh() }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)

        // Plain mailto link. NSWorkspace.open delegates to the user's
        // default mail handler (Mail.app, Gmail-via-browser, etc.); no
        // dependency on a specific client. Text-only to match the
        // surrounding footer chrome.
        Button("Feedback") {
          if let url = URL(string: "mailto:support@sunriselabs.ai") {
            NSWorkspace.shared.open(url)
          }
        }
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
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  private func relative(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
  }
}
