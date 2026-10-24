import SwiftUI
import UserNotifications

@main
struct LoopsApp: App {
  @State private var store = Store()

  init() {
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "--icon"), i + 1 < args.count {
      exit(AppIcon.write(to: args[i + 1]) ? 0 : 1)
    }
    UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
    Notify.register()
    UserDefaults.standard.removeObject(forKey: "AppleAccentColor")
    UserDefaults.standard.removeObject(forKey: "AppleHighlightColor")
  }

  var body: some Scene {
    Window("Loops", id: "loops") {
      LoopsWindow()
        .environment(store)
        .frame(minWidth: 900, minHeight: 560)
    }
    .defaultSize(width: 1240, height: 820)
    .defaultLaunchBehavior(.presented)
    .commands {
      LoopsCommands(store: store)
      ActionCommands(store: store)
      TableCommands()
    }

    MenuBarExtra {
      MenuBarMenu().environment(store)
    } label: {
      let alert = store.phase == .limited || { if case .blocked = store.phase { true } else { false } }()
      let icon =
        alert
        ? Image(icon: "exclamationmark.triangle")
        : Image(nsImage: MenuGlyph.image(working: !store.running.isEmpty, badge: !CI.shared.board.blocked.isEmpty))
      let waiting = store.inbox.count
      if waiting == 0 {
        icon
      } else {
        Label { Text("\(waiting)") } icon: { icon }.labelStyle(.titleAndIcon)
      }
    }
    .menuBarExtraStyle(.menu)

    Settings {
      SettingsView().environment(store)
    }
  }
}
