import SwiftUI
import UserNotifications

@main
struct LoopsApp: App {
  @State private var workspace = Workspace()

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
      WorkspaceWindow()
        .environment(workspace)
        .frame(minWidth: 900, minHeight: 560)
    }
    .defaultSize(width: 1240, height: 820)
    .defaultLaunchBehavior(.presented)
    .commands {
      LoopsCommands(workspace: workspace)
      ActionCommands(workspace: workspace)
      TableCommands()
    }

    MenuBarExtra {
      MenuBarMenu().environment(workspace)
    } label: {
      let stores = workspace.projects
      let alert = stores.contains { s in
        if case .blocked = s.phase { return true }
        return s.phase == .limited
      }
      let icon =
        alert
        ? Image(icon: "exclamationmark.triangle")
        : Image(
          nsImage: MenuGlyph.image(
            working: stores.contains { !$0.running.isEmpty }, badge: stores.contains { !$0.ci.board.blocked.isEmpty }))
      let waiting = stores.map(\.inbox.count).reduce(0, +)
      if waiting == 0 {
        icon
      } else {
        Label { Text("\(waiting)") } icon: { icon }.labelStyle(.titleAndIcon)
      }
    }
    .menuBarExtraStyle(.menu)

    Settings {
      SettingsView().environment(workspace)
    }
  }
}
