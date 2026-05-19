import SwiftUI
import AppKit

@main
struct MessagesForAIMenuApp: App {
  @StateObject private var store = DraftStore()
  @StateObject private var loginItem = LoginItemController()
  @StateObject private var settings = SettingsStore()
  @StateObject private var contactsExporter = ContactsExporter()
  @StateObject private var whatsappDaemon = WhatsAppDaemonController()
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene {
    MenuBarExtra {
      DraftListView()
        .environmentObject(store)
        .environmentObject(loginItem)
        .environmentObject(settings)
        .environmentObject(contactsExporter)
        .environmentObject(whatsappDaemon)
        .task {
          // Kick off the Contacts export on first popover render. Using
          // .task rather than .onAppear so async work is properly cancelled
          // on view disappearance. Bootstrap is idempotent — safe across
          // multiple popover opens.
          await contactsExporter.bootstrap()
          // Spawn the WhatsApp daemon if the user has the transport
          // enabled. Idempotent — safe across multiple popover renders.
          if settings.whatsappEnabled {
            whatsappDaemon.start()
          }
          // Hand the daemon controller to the AppDelegate so it can
          // stop the daemon synchronously on app quit.
          appDelegate.whatsappDaemon = whatsappDaemon
        }
    } label: {
      // Dynamic label: badge count when there are pending drafts.
      // SF Symbols + Text composed via Image+Text in a HStack would not
      // render in MenuBarExtra; use a single Label or just the symbol.
      MenuBarLabel(pending: store.drafts.filter { !$0.isSent }.count)
    }
    .menuBarExtraStyle(.window)
  }
}

private struct MenuBarLabel: View {
  let pending: Int
  var body: some View {
    if pending == 0 {
      Image(systemName: "message")
    } else {
      // System symbol "<x>.badge" doesn't accept dynamic counts; pair an
      // icon with a small numeric Text instead. macOS will render this in
      // the menu bar at the icon's height.
      Label {
        Text("\(pending)")
      } icon: {
        Image(systemName: "message.fill")
      }
    }
  }
}

// LSUIElement is set in Info.plist (see install.sh wrapping), which hides
// the Dock icon for SwiftUI apps built via SPM. We also call
// setActivationPolicy(.accessory) at launch as a belt-and-suspenders
// fallback for ad hoc / unbundled runs (e.g. `swift run`).
final class AppDelegate: NSObject, NSApplicationDelegate {
  /// Set by the popover's .task closure. Lets us SIGTERM the daemon
  /// from `applicationWillTerminate` without having to walk SwiftUI
  /// state from AppKit.
  var whatsappDaemon: WhatsAppDaemonController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
  }

  func applicationWillTerminate(_ notification: Notification) {
    // Synchronous SIGTERM → up to 5s wait → SIGKILL. Blocks app exit
    // briefly so the daemon gets a chance to flush its session DB.
    whatsappDaemon?.stopBlocking()
  }
}
