import Foundation

enum Page: Hashable {
  case home, inbox, pulls, tasks, schedule, checks, spend, plan
  case loop(String)
  case task(String)

  static let top: [Page] = [.home, .inbox, .pulls, .tasks, .schedule, .checks, .spend, .plan]

  var id: String {
    switch self {
    case .home: "home"
    case .inbox: "inbox"
    case .pulls: "pulls"
    case .tasks: "tasks"
    case .schedule: "schedule"
    case .checks: "checks"
    case .spend: "spend"
    case .plan: "plan"
    case .loop(let name): name
    case .task(let id): "task:\(id)"
    }
  }

  init?(id: String) {
    switch id {
    case "home", "overview": self = .home
    case "inbox", "waiting": self = .inbox
    case "pulls", "results": self = .pulls
    case "tasks", "goals": self = .tasks
    case "schedule": self = .schedule
    case "checks", "ci": self = .checks
    case "spend": self = .spend
    case "plan": self = .plan
    default:
      if id.hasPrefix("task:"), id.count > 5 {
        self = .task(String(id.dropFirst(5)))
      } else if id.hasPrefix("loop-") {
        self = .loop(id)
      } else {
        return nil
      }
    }
  }

  var title: String {
    switch self {
    case .home: "Home"
    case .inbox: "Inbox"
    case .pulls: "Pull Requests"
    case .tasks: "Tasks"
    case .schedule: "Schedule"
    case .checks: "Checks"
    case .spend: "Spend"
    case .plan: "Plan"
    case .loop(let name): LoopSpec.short(name)
    case .task: "Task"
    }
  }

  var symbol: String {
    switch self {
    case .home: "square.grid.2x2"
    case .inbox: "tray"
    case .pulls: "arrow.trianglehead.pull"
    case .tasks: "checklist"
    case .schedule: "calendar"
    case .checks: "checkmark.seal"
    case .spend: "chart.bar.xaxis"
    case .plan: "map"
    case .loop(let name): Symbols.loop(name)
    case .task: Symbols.askClaude
    }
  }
}
