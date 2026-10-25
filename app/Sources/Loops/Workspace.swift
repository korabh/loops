import AppKit
import SwiftUI

@MainActor @Observable
final class Workspace {
  static weak var current: Workspace?

  private(set) var projects: [Store] = []
  let jobs = JobWatcher(configs: [])
  var selection: String? {
    didSet { UserDefaults.standard.set(selection, forKey: Self.selectionKey) }
  }
  var adding = false
  var problem: String?
  @ObservationIgnored var openWindow: OpenWindowAction?
  @ObservationIgnored private var server: HookServer?

  private static let selectionKey = "selectedProject"
  private static let migratedKey = "projectsMigrated"
  static let projectKeys = [
    "tasks", "dismissed", "queuedFollowUps", "modelPRs", "recall",
    "directions", "directionsAt", "directionsUsage", "directionsFingerprint", "directionsDestination", "dismissedDirections", "destination",
    "goalIdeas", "goalIdeasAt", "dismissedGoalIdeas", "goalIdeasUsage",
    "proposal", "featureIdeas", "featureIdeasAt", "featureIdeasUsage",
  ]

  init() {
    selection = UserDefaults.standard.string(forKey: Self.selectionKey)
    Workspace.current = self
    NotificationDelegate.shared.workspace = self
    listen()
    load()
    NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) {
      [weak self] _ in
      MainActor.assumeIsolated {
        guard let jobs = self?.jobs else { return }
        Task { await jobs.reconcile(every: 60) }
      }
    }
    Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(60))
        guard let self, Self.registered() != self.projects.map(\.id).sorted() else { continue }
        self.load()
      }
    }
  }

  var focus: Store? { selection.flatMap(store) ?? ordered.first }
  var ordered: [Store] { projects.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }

  func store(_ id: String?) -> Store? { projects.first { $0.id == id } }

  func show(_ id: String, _ page: Page? = nil, inbox: String? = nil) {
    guard let s = store(id) else { return }
    if let page {
      s.inboxSelection = inbox
      s.page = page
    }
    selection = id
    ProjectTabs.joinNext()
    openWindow?(value: id)
    NSApp.activate()
  }

  func showAll() {
    openWindow?(id: "all")
    NSApp.activate()
  }

  func choose(then open: ((String) -> Void)? = nil) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Add Project"
    panel.message = "Choose a git repository whose loops this Mac runs."
    NSApp.activate()
    guard panel.runModal() == .OK, let url = panel.url else { return }
    add(url, then: open)
  }

  static func status(_ stores: [Store]) -> String {
    let running = stores.map(\.running.count).reduce(0, +)
    let waiting = stores.map(\.inbox.count).reduce(0, +)
    let parts = [running > 0 ? "\(running) running" : nil, waiting > 0 ? "\(waiting) waiting on you" : nil].compactMap { $0 }
    if !parts.isEmpty { return parts.joined(separator: " · ") }
    return stores.count == 1 ? stores[0].phase.label : "Nothing waiting"
  }

  static func registered() -> [String] {
    let listed = Registry.read()?.projects.map { Array($0.keys) } ?? []
    let pinned = (Bundle.main.infoDictionary?["LoopsRepo"] as? String).map { [$0] } ?? []
    return Array(Set(listed + pinned)).filter { FileManager.default.fileExists(atPath: $0 + "/.git") }.sorted()
  }

  static func defaults(for repo: String) -> UserDefaults {
    let name = repo.trimmingCharacters(in: CharacterSet(charactersIn: "/")).replacingOccurrences(of: "/", with: ".")
    return UserDefaults(suiteName: "io.github.korabh.loops.project.\(name)") ?? .standard
  }

  func load() {
    let wanted = Self.registered()
    migrate(wanted)
    var next = projects.filter { wanted.contains($0.id) }
    for gone in projects where !wanted.contains(gone.id) { gone.stop() }
    for repo in wanted where !next.contains(where: { $0.id == repo }) {
      let store = Store(repo: URL(fileURLWithPath: repo), defaults: Self.defaults(for: repo), jobs: jobs)
      if let url = server?.url { store.useHooks(url) }
      next.append(store)
    }
    projects = next
    jobs.watch(next.flatMap(\.configs))
    if let s = selection, store(s) == nil { selection = nil }
    if projects.count == 1 { selection = projects[0].id }
  }

  func add(_ folder: URL, then open: ((String) -> Void)? = nil) {
    guard !adding else { return }
    let repo = folder.standardizedFileURL
    guard FileManager.default.fileExists(atPath: repo.appending(path: ".git").path) else {
      problem = "\(repo.lastPathComponent) is not the top of a git repository."
      return
    }
    adding = true
    problem = nil
    Task {
      let (code, out) = await Shell.run(Paths.bin.appending(path: "loop-runner"), ["state"], in: repo)
      adding = false
      if code != 0 {
        problem = out.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init) ?? "loop-runner could not register it."
        return
      }
      load()
      guard let added = Self.registered().first(where: { $0 == repo.path }) else { return }
      if let open {
        selection = added
        open(added)
      } else {
        show(added)
      }
    }
  }

  func remove(_ store: Store) {
    Task {
      let (code, out) = await Shell.run(store.paths.script, ["forget"], in: store.paths.repo)
      if code != 0 {
        problem = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return
      }
      problem = nil
      if selection == store.id { selection = nil }
      load()
    }
  }

  func setNotifyAll(_ on: Bool) {
    UserDefaults.standard.set(on, forKey: "notifyAll")
    for s in projects { s.notifyAll = on }
    if on { Task { await Notify.authorize() } }
  }

  func setAppearance(_ a: Appearance) {
    UserDefaults.standard.set(a.rawValue, forKey: "appearance")
    for s in projects { s.appearance = a }
    NSApp.appearance = a.nsAppearance
  }

  private func listen() {
    let standard = UserDefaults.standard
    let token = standard.string(forKey: "hookToken") ?? UUID().uuidString.lowercased()
    standard.set(token, forKey: "hookToken")
    let server = HookServer(token: token) { [weak self] event in
      DispatchQueue.main.async { MainActor.assumeIsolated { self?.route(event) } }
    }
    server.start()
    self.server = server
  }

  private func route(_ e: HookEvent) {
    let owners = projects.filter { $0.owns(e) }
    for s in owners.isEmpty ? projects : owners { s.receive(e) }
  }

  private func migrate(_ wanted: [String]) {
    let standard = UserDefaults.standard
    guard !standard.bool(forKey: Self.migratedKey) else { return }
    let pinned = Bundle.main.infoDictionary?["LoopsRepo"] as? String
    guard let target = pinned.flatMap({ wanted.contains($0) ? $0 : nil }) ?? Self.home(of: standard.data(forKey: "tasks"), among: wanted) ?? wanted.first
    else { return }
    Self.carry(Self.projectKeys, from: standard, to: Self.defaults(for: target))
    standard.set(true, forKey: Self.migratedKey)
  }

  static func home(of tasks: Data?, among repos: [String]) -> String? {
    guard let tasks, let list = (try? JSONSerialization.jsonObject(with: tasks)) as? [[String: Any]] else { return nil }
    let cwds = list.compactMap { $0["cwd"] as? String }
    let counts = repos.map { r in (r, cwds.filter { $0 == r || $0.hasPrefix(r + "/") }.count) }
    return counts.filter { $0.1 > 0 }.max { $0.1 < $1.1 }?.0
  }

  static func carry(_ keys: [String], from: UserDefaults, to: UserDefaults) {
    for key in keys {
      if to.object(forKey: key) == nil, let value = from.object(forKey: key) { to.set(value, forKey: key) }
    }
  }
}
