import SwiftUI
import AppKit
import Contacts

struct DraftListView: View {
  @EnvironmentObject var store: DraftStore
  @EnvironmentObject var loginItem: LoginItemController
  @EnvironmentObject var settings: SettingsStore
  @EnvironmentObject var contactsExporter: ContactsExporter

  /// Onboarding / Settings / Pairing all open as separate SwiftUI
  /// Windows (registered in App.swift) so they get real focus and
  /// don't fight the popover's transient-dismiss behavior. From the
  /// popover, we just openWindow them by id.
  @Environment(\.openWindow) private var openWindow

  private var pending: [Draft] { store.drafts.filter { !$0.isSent } }
  // Cap for the inner ScrollView. We subtract a rough estimate of the
  // surrounding chrome (header + divider + footer + padding ~ 180pt)
  // from the screen's `visibleFrame.height` (which macOS already
  // computes net of menu bar + dock). ScrollView grows to fit content
  // up to this cap; beyond it, the ScrollView scrolls. This makes the
  // popover "grow as needed" up to right above the dock.
  private static let chromeEstimate: CGFloat = 180

  private var maxScrollHeight: CGFloat {
    let screenH = NSScreen.main?.visibleFrame.height ?? 900
    return max(360, screenH - Self.chromeEstimate)
  }

  private var recentlySent: [Draft] {
    // 24-hour visible window for sent drafts. The on-disk draft JSON and
    // the ~/.messages-mcp/send-audit.log keep forever — this is just the
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

      // Contacts-permission banner — the menu bar app's only TCC
      // dependency under the sidecar architecture. The FDA banner
      // that lived here previously was misleading: it probed the
      // menu bar app's own FDA grant, but the only process that
      // actually needs FDA is the imessage-drafts-mcp binary (for chat.db
      // thread-context reads). That signal is surfaced per-draft
      // via the context_diagnostic in the Details disclosure.
      ContactsPermissionBanner()
        .padding(.horizontal, 12)
        .padding(.top, contactsExporter.authorizationStatus == .authorized ? 0 : 8)

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
      // ScrollView naturally sizes to its content up to maxScrollHeight,
      // beyond which it starts scrolling. maxScrollHeight is derived
      // from `NSScreen.main.visibleFrame.height` (which macOS computes
      // net of menu bar + dock), so the popover never reaches into
      // the dock. minHeight is a small floor for the empty state so
      // the popover doesn't collapse to a sliver when there are no
      // pending drafts.
      .frame(minHeight: 200, maxHeight: maxScrollHeight)

      Divider()
      footer
    }
    .frame(width: 420)
    .onAppear {
      // Auto-open onboarding on first popover render. Subsequent
      // renders skip this (firstRunComplete flips to true on commit).
      if !settings.firstRunComplete {
        openWindow(id: WindowID.onboarding)
      } else if !settings.walkthroughComplete && !settings.walkthroughSkipped {
        // Upgrade path: existing v0.3.0/v0.3.1 users have first_run_complete=true
        // but no walkthrough flag in their settings.json (absence == false).
        // Show the walkthrough once — these are precisely the users hit by the
        // discoverability bug PR #14 fixed.
        openWindow(id: WindowID.setupWalkthrough)
      }
    }
  }

  // MARK: - Sections

  private var header: some View {
    HStack {
      Image(systemName: "message.badge")
        .foregroundStyle(.tint)
      Text("Messages for AI")
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
            // Prefer the resolved name (set by the daemon at stage time
            // from the contacts table / phone-format fallback) — the raw
            // JID is uninformative ("12158055729@s.whatsapp.net" vs
            // "James Stine Heath"). Falls back to the JID when no name
            // could be resolved (which mostly happens for @lid privacy
            // senders the contacts table doesn't have mapped yet).
            Text(draft.to_handle_name ?? draft.to_handle)
              .font(.caption.weight(.medium))
              .lineLimit(1)
              .truncationMode(.middle)
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
      if let err = loginItem.lastError {
        Text(err)
          .font(.caption2)
          .foregroundStyle(.red)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      // Action row. Per-transport toggles moved into the Settings
      // sheet in v0.3.0 — this row stays focused on app actions.
      HStack(spacing: 12) {
        Button("Refresh") { store.refresh() }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)

        Button {
          openWindow(id: WindowID.settings)
          // openWindow won't refocus an already-open Settings window on
          // another Space/display — pull it to the front explicitly.
          WindowFocus.bringToFront(id: WindowID.settings, title: WindowTitle.settings)
        } label: {
          HStack(spacing: 4) {
            Image(systemName: "gearshape")
            Text("Settings…")
          }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)

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
