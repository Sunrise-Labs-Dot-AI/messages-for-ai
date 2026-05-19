import SwiftUI
import AppKit
import Contacts

struct DraftListView: View {
  @EnvironmentObject var store: DraftStore
  @EnvironmentObject var loginItem: LoginItemController
  @EnvironmentObject var settings: SettingsStore
  @EnvironmentObject var contactsExporter: ContactsExporter

  /// True when whatsapp-mcp appears to be installed locally. Cheap
  /// check — just looks for the umbrella state directory. We don't
  /// probe the daemon socket here; that's the pairing sheet's job and
  /// it surfaces a clearer error if the daemon is installed-but-dead.
  /// Mirrors the same feature flag DraftStore uses to enable the
  /// WhatsApp watcher.
  private var whatsappInstalled: Bool {
    FileManager.default.fileExists(atPath:
      FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".whatsapp-mcp").path
    )
  }

  /// Drives the pairing sheet's presentation. Bound into the sheet so
  /// it can self-dismiss on `state.update: connected`.
  @State private var showPairingSheet = false

  /// First-run onboarding sheet. Auto-presents when SettingsStore says
  /// the first-run sentinel is absent. Initialized in `.task` since
  /// `@EnvironmentObject` isn't available at property-init time.
  @State private var showOnboardingSheet = false

  /// Set by OnboardingView when the user opts into WhatsApp. We chain
  /// directly into the pairing sheet after onboarding dismisses, so
  /// the user doesn't have to find the "Connect WhatsApp" button.
  @State private var wantsWhatsAppPairing = false

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
    .sheet(isPresented: $showPairingSheet) {
      WhatsAppPairingView(isPresented: $showPairingSheet)
    }
    .sheet(isPresented: $showOnboardingSheet) {
      OnboardingView(
        isPresented: $showOnboardingSheet,
        wantsWhatsAppPairing: $wantsWhatsAppPairing
      )
    }
    .onAppear {
      // Auto-present onboarding on first popover render. Subsequent
      // renders skip this (firstRunComplete flips to true on commit).
      if !settings.firstRunComplete {
        showOnboardingSheet = true
      }
    }
    .onChange(of: showOnboardingSheet) { isOpen in
      // After onboarding closes, chain into pairing if WhatsApp was
      // checked. The daemon was kicked up by OnboardingView.commit()
      // so the QR should appear within ~1s.
      if !isOpen && wantsWhatsAppPairing {
        wantsWhatsAppPairing = false
        showPairingSheet = true
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

        // Only show the WhatsApp pair entry point when the user has
        // whatsapp-mcp installed. Hiding it entirely on machines
        // without the daemon is less visually noisy than showing a
        // disabled button, and matches the rest of the feature flag
        // (DraftStore won't be watching the WhatsApp dir anyway).
        if whatsappInstalled {
          Button {
            showPairingSheet = true
          } label: {
            HStack(spacing: 4) {
              Image(systemName: Platform.whatsapp.sfSymbol)
              Text("Connect WhatsApp")
            }
          }
          .buttonStyle(.plain)
          .foregroundStyle(Platform.whatsapp.accentColor)
          .help("Pair this Mac to your WhatsApp account via QR scan")
        }

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
