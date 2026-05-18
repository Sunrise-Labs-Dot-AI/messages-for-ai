import SwiftUI
import AppKit

@main
struct MessagesForAIMenuApp: App {
  @StateObject private var store = DraftStore()
  @StateObject private var loginItem = LoginItemController()
  @StateObject private var settings = SettingsStore()
  @StateObject private var contactsExporter = ContactsExporter()
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene {
    MenuBarExtra {
      DraftListView()
        .environmentObject(store)
        .environmentObject(loginItem)
        .environmentObject(settings)
        .environmentObject(contactsExporter)
        .task {
          // Kick off the Contacts export on first popover render. Using
          // .task rather than .onAppear so async work is properly cancelled
          // on view disappearance. Bootstrap is idempotent — safe across
          // multiple popover opens.
          await contactsExporter.bootstrap()
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
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
  }
}
