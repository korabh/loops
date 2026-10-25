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
    WindowGroup("Project", id: "project", for: String.self) { $id in
      ProjectWindow(id: $id)
        .environment(workspace)
        .frame(minWidth: 900, minHeight: 560)
    } defaultValue: {
      Workspace.current?.focus?.id ?? ""
    }
    .defaultSize(width: 1240, height: 820)
    .defaultLaunchBehavior(.presented)
    .commands {
      LoopsCommands(workspace: workspace)
      ActionCommands()
      ViewCommands()
      TableCommands()
    }

    Window("All Projects", id: "all") {
      AllProjectsWindow()
        .environment(workspace)
        .frame(minWidth: 760, minHeight: 480)
    }
    .defaultSize(width: 1100, height: 760)

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
