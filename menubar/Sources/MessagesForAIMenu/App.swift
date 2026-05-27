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

/// Window titles, hoisted so the focus helper can match a window by title
/// without drifting from the scene definitions below.
enum WindowTitle {
  static let settings = "Messages for AI Settings"
}

/// Reliably bring a SwiftUI `Window(id:)` to the foreground from a menu-bar
/// (.accessory) app. `openWindow` alone does NOT refocus a window that's
/// already open on another Space/display — the app may not be frontmost and
/// the window stays where it was, so the user has to hunt it down. This
/// activates the app and pulls the window to the *active* Space instead.
enum WindowFocus {
  static func bringToFront(id: String, title: String) {
    NSApp.activate(ignoringOtherApps: true)
    // Defer one runloop tick so this runs after openWindow has surfaced
    // (or created) the window.
    DispatchQueue.main.async {
      guard let window = NSApp.windows.first(where: {
        $0.identifier?.rawValue == id || $0.title == title
      }) else { return }
      // Let the window come to whatever Space the user is on now, rather
      // than yanking the user across Spaces to where it last lived.
      window.collectionBehavior.insert(.moveToActiveSpace)
      window.makeKeyAndOrderFront(nil)
    }
  }
}

@main
struct MessagesForAIMenuApp: App {
  @StateObject private var store = DraftStore()
  @StateObject private var loginItem = LoginItemController()
  @StateObject private var settings = SettingsStore()
  @StateObject private var contactsExporter = ContactsExporter()
  @StateObject private var whatsappDaemon = WhatsAppDaemonController()
  @StateObject private var imessageDaemon = IMessageDaemonController()
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
          // The iMessage daemon is started from the menu-bar label's onAppear
          // (fires reliably at launch) — no redundant start() here, which would
          // otherwise reset the crash-loop counter on a second call.
          if settings.whatsappEnabled {
            whatsappDaemon.start()
          }
          appDelegate.whatsappDaemon = whatsappDaemon
        }
    } label: {
      MenuBarLabel(pending: store.drafts.filter { !$0.isSent }.count)
        .onAppear {
          // The label renders at app launch (the icon is always shown),
          // unlike the popover content's `.task` which only fires when the
          // popover is first opened. iMessage is the core feature, so its
          // FDA-holding daemon must come up on launch regardless. start()
          // is idempotent, so the .task call below is a harmless backstop.
          imessageDaemon.start()
          appDelegate.imessageDaemon = imessageDaemon
        }
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

    Window(WindowTitle.settings, id: WindowID.settings) {
      SettingsView()
        .environmentObject(settings)
        .environmentObject(loginItem)
        .environmentObject(whatsappDaemon)
        .environmentObject(imessageDaemon)
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
  var imessageDaemon: IMessageDaemonController?

  /// Number of secondary SwiftUI Windows currently visible. When
  /// non-zero we flip to `.regular` (Dock icon + ⌘Tab presence);
  /// when it returns to zero we drop back to `.accessory`.
  private var visibleWindows = 0

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
  }

  func applicationWillTerminate(_ notification: Notification) {
    imessageDaemon?.stopBlocking()
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
