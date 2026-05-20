import SwiftUI
import AppKit

/// Window identifiers used with @Environment(\.openWindow) /
/// dismissWindow. Kept in one place so callers don't typo a string.
enum WindowID {
  static let onboarding = "onboarding"
  static let settings = "settings"
  static let whatsappPairing = "whatsapp-pairing"
  static let setupWalkthrough = "setup-walkthrough"
}

@main
struct MessagesForAIMenuApp: App {
  @StateObject private var store = DraftStore()
  @StateObject private var loginItem = LoginItemController()
  @StateObject private var settings = SettingsStore()
  @StateObject private var contactsExporter = ContactsExporter()
  @StateObject private var whatsappDaemon = WhatsAppDaemonController()
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene {
    // The menu bar popover — fast-access surface. Stays as a transient
    // popover (clicks-outside dismiss is the expected behavior for the
    // daily draft-list view).
    MenuBarExtra {
      DraftListView()
        .environmentObject(store)
        .environmentObject(loginItem)
        .environmentObject(settings)
        .environmentObject(contactsExporter)
        .environmentObject(whatsappDaemon)
        .task {
          await contactsExporter.bootstrap()
          if settings.whatsappEnabled {
            whatsappDaemon.start()
          }
          appDelegate.whatsappDaemon = whatsappDaemon
        }
    } label: {
      MenuBarLabel(pending: store.drafts.filter { !$0.isSent }.count)
    }
    .menuBarExtraStyle(.window)

    // Onboarding / Settings / WhatsApp pairing live in their own real
    // Windows (not sheets on the popover). Sheets inside MenuBarExtra(
    // .window) present in a separate NSWindow that steals focus from
    // the transient popover and dismisses it — toggle clicks then
    // collapse the whole UI. Real Windows have their own focus
    // lifecycle and don't fight the popover.
    //
    // While any of these windows are visible the app flips activation
    // policy from .accessory → .regular (see AppDelegate window
    // counters), which surfaces a Dock icon Wispr Flow-style. When the
    // last window closes it flips back to .accessory and the app
    // returns to its menu-bar-only ambient state.
    Window("Welcome to Messages for AI", id: WindowID.onboarding) {
      OnboardingView()
        .environmentObject(settings)
        .environmentObject(whatsappDaemon)
        .frame(width: 460)
        .fixedSize()
        .trackWindowLifecycle(appDelegate: appDelegate)
    }
    .windowResizability(.contentSize)

    Window("Messages for AI Settings", id: WindowID.settings) {
      SettingsView()
        .environmentObject(settings)
        .environmentObject(loginItem)
        .environmentObject(whatsappDaemon)
        .frame(width: 480)
        .frame(minHeight: 360)
        .trackWindowLifecycle(appDelegate: appDelegate)
    }
    .windowResizability(.contentSize)

    Window("Connect WhatsApp", id: WindowID.whatsappPairing) {
      WhatsAppPairingView()
        .environmentObject(whatsappDaemon)
        .environmentObject(settings)
        .frame(width: 380, height: 480)
        .trackWindowLifecycle(appDelegate: appDelegate)
    }
    .windowResizability(.contentSize)

    Window("Setup Walkthrough", id: WindowID.setupWalkthrough) {
      SetupWalkthroughView()
        .environmentObject(settings)
        .environmentObject(whatsappDaemon)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 540, idealHeight: 640)
        .trackWindowLifecycle(appDelegate: appDelegate)
    }
    .windowResizability(.contentSize)
  }
}

private struct MenuBarLabel: View {
  let pending: Int
  var body: some View {
    if pending == 0 {
      Image(systemName: "message")
    } else {
      Label {
        Text("\(pending)")
      } icon: {
        Image(systemName: "message.fill")
      }
    }
  }
}

/// Lifecycle hooks for a SwiftUI Window — bumps the AppDelegate's
/// visible-window counter so the activation policy can flip between
/// .accessory and .regular based on whether any non-menubar window
/// is currently shown.
private struct TrackWindowLifecycle: ViewModifier {
  let appDelegate: AppDelegate

  func body(content: Content) -> some View {
    content
      .onAppear { appDelegate.windowDidOpen() }
      .onDisappear { appDelegate.windowDidClose() }
  }
}

private extension View {
  func trackWindowLifecycle(appDelegate: AppDelegate) -> some View {
    modifier(TrackWindowLifecycle(appDelegate: appDelegate))
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  /// Set by the popover's .task closure. Lets us SIGTERM the daemon
  /// from `applicationWillTerminate` without having to walk SwiftUI
  /// state from AppKit.
  var whatsappDaemon: WhatsAppDaemonController?

  /// Number of secondary SwiftUI Windows currently visible. When
  /// non-zero we flip to `.regular` (Dock icon + ⌘Tab presence);
  /// when it returns to zero we drop back to `.accessory`.
  private var visibleWindows = 0

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
  }

  func applicationWillTerminate(_ notification: Notification) {
    whatsappDaemon?.stopBlocking()
  }

  /// When the user closes every window, macOS would normally exit a
  /// regular app — but we want to keep the menu bar alive. Returning
  /// false from this delegate hook keeps the process running.
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  // MARK: - Window-count bookkeeping

  func windowDidOpen() {
    visibleWindows += 1
    if visibleWindows == 1 {
      NSApp.setActivationPolicy(.regular)
      NSApp.activate(ignoringOtherApps: true)
    }
  }

  func windowDidClose() {
    visibleWindows = max(0, visibleWindows - 1)
    if visibleWindows == 0 {
      NSApp.setActivationPolicy(.accessory)
    }
  }
}
