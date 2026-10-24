import AppKit
import UserNotifications

final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
  static let shared = NotificationDelegate()

  @MainActor weak var workspace: Workspace?

  func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound, .list])
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let info = response.notification.request.content.userInfo
    let project = info["project"] as? String
    let task = info["task"] as? String
    let pr = info["pr"] as? Int
    let action = response.actionIdentifier
    let text = (response as? UNTextInputNotificationResponse)?.userText
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        guard let w = self.workspace, let store = w.store(project) ?? w.focus else { return }
        if w.projects.count > 1 { w.selection = store.id }
        store.handle(action: action, task: task, pr: pr, text: text)
      }
      completionHandler()
    }
  }
}

enum Notify {
  static let answer = "answer"
  static let ready = "ready"

  static func authorize() async {
    _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
  }

  static func register() {
    let open = UNNotificationAction(identifier: "open", title: "Open", options: [.foreground])
    let reply = UNTextInputNotificationAction(
      identifier: "reply", title: "Answer", options: [], textInputButtonTitle: "Send", textInputPlaceholder: "Your answer")
    let merge = UNNotificationAction(identifier: "merge", title: "Merge", options: [])
    UNUserNotificationCenter.current().setNotificationCategories([
      UNNotificationCategory(identifier: answer, actions: [reply, open], intentIdentifiers: []),
      UNNotificationCategory(identifier: ready, actions: [merge, open], intentIdentifiers: []),
    ])
  }

  static func post(title: String, body: String, category: String? = nil, info: [String: Any] = [:]) {
    NSSound(named: "Glass")?.play()
    Task {
      let content = UNMutableNotificationContent()
      content.title = title
      content.body = body
      content.sound = .default
      if let category { content.categoryIdentifier = category }
      content.userInfo = info
      try? await UNUserNotificationCenter.current().add(
        UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
  }
}
