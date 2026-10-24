import AppIntents
import AppKit

struct LoopEntity: AppEntity {
  static let typeDisplayRepresentation: TypeDisplayRepresentation = "Loop"
  static let defaultQuery = LoopQuery()

  let id: String
  let title: String

  var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
}

struct LoopQuery: EntityStringQuery {
  @MainActor private func all() -> [LoopEntity] {
    guard let store = Store.current else { return [] }
    let specs = store.specs.isEmpty ? ProjectConfig.read(store.paths.config)?.specs ?? [] : store.specs
    return specs.map { LoopEntity(id: $0.name, title: $0.title) }
  }

  @MainActor func entities(for identifiers: [String]) async throws -> [LoopEntity] {
    all().filter { identifiers.contains($0.id) }
  }

  @MainActor func entities(matching string: String) async throws -> [LoopEntity] {
    all().filter { $0.title.localizedCaseInsensitiveContains(string) || $0.id.localizedCaseInsensitiveContains(string) }
  }

  @MainActor func suggestedEntities() async throws -> [LoopEntity] { all() }
}

enum IntentFailure: Error, CustomLocalizedStringResourceConvertible {
  case notReady
  case busy(String)

  var localizedStringResource: LocalizedStringResource {
    switch self {
    case .notReady: "Loops is still starting. Try again in a moment."
    case .busy(let title): "\(title) is already running."
    }
  }
}

struct RunLoopIntent: AppIntent {
  static let title: LocalizedStringResource = "Run Loop"
  static let description = IntentDescription("Starts a loop now instead of waiting for its next tick.")

  @Parameter(title: "Loop")
  var loop: LoopEntity

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    guard let store = Store.current else { throw IntentFailure.notReady }
    guard store.running[loop.id] == nil, !store.isStarting(loop.id) else { throw IntentFailure.busy(loop.title) }
    store.runNow(loop.id)
    return .result(dialog: "Started \(loop.title).")
  }
}

struct StartTaskIntent: AppIntent {
  static let title: LocalizedStringResource = "Start Task"
  static let description = IntentDescription("Starts a Claude Code task in the background, in its own worktree.")

  @Parameter(title: "Task", inputOptions: String.IntentInputOptions(multiline: true))
  var prompt: String

  @Parameter(title: "Loop")
  var loop: LoopEntity?

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    guard let store = Store.current else { throw IntentFailure.notReady }
    store.ask(prompt, loop: loop?.id)
    return .result(dialog: "Claude Code is on it.")
  }
}

struct OpenInboxIntent: AppIntent {
  static let title: LocalizedStringResource = "Open Inbox"
  static let description = IntentDescription("Shows what needs you: answers, merges, fixes and decisions.")
  static let openAppWhenRun = true

  @MainActor
  func perform() async throws -> some IntentResult {
    guard let store = Store.current else { throw IntentFailure.notReady }
    store.page = .inbox
    store.showWindow?()
    NSApp.activate()
    return .result()
  }
}

struct OpenLoopIntent: OpenIntent {
  static let title: LocalizedStringResource = "Open Loop"

  @Parameter(title: "Loop")
  var target: LoopEntity

  @MainActor
  func perform() async throws -> some IntentResult {
    guard let store = Store.current else { throw IntentFailure.notReady }
    store.page = .loop(target.id)
    store.showWindow?()
    NSApp.activate()
    return .result()
  }
}

struct LoopsShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: RunLoopIntent(),
      phrases: ["Run \(\.$loop) in \(.applicationName)", "Run a loop in \(.applicationName)"],
      shortTitle: "Run Loop", systemImageName: "play")
    AppShortcut(
      intent: StartTaskIntent(), phrases: ["Start a task in \(.applicationName)", "Ask \(.applicationName) to do something"],
      shortTitle: "Start Task", systemImageName: "plus")
    AppShortcut(
      intent: OpenInboxIntent(), phrases: ["Open \(.applicationName) inbox", "What needs me in \(.applicationName)"],
      shortTitle: "Inbox", systemImageName: "tray")
    AppShortcut(
      intent: OpenLoopIntent(), phrases: ["Open \(\.$target) in \(.applicationName)"], shortTitle: "Open Loop",
      systemImageName: "repeat")
  }
}
