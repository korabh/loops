import AppKit
import Observation
import SwiftUI

enum Phase: Equatable {
  case unknown, stopped, limited, working, idle
  case blocked(String)

  var label: String {
    switch self {
    case .unknown: "Status unknown"
    case .stopped: "Stopped"
    case .limited: "At its usage limit"
    case .working: "Working"
    case .idle: "Idle"
    case .blocked(let why): ["blocked", "failed"].contains(why) ? "Stopped" : "Blocked: \(why)"
    }
  }

  var tint: Color {
    switch self {
    case .working: .green
    case .idle: .secondary
    case .limited: .orange
    case .blocked: .red
    case .unknown, .stopped: .secondary
    }
  }

  var symbol: String {
    switch self {
    case .working: "waveform"
    case .limited: "hourglass"
    case .blocked: "exclamationmark.triangle"
    case .stopped: "stop.circle"
    default: "checkmark.circle"
    }
  }

  var healthy: Bool { self == .idle || self == .working }
}

enum Standing { case running, due, resting, outside, off }

enum Shell {
  static func run(_ script: URL, _ args: [String], in repo: URL, qos: QualityOfService = .userInitiated) async -> (Int32, String) {
    await exec(["bash", script.path] + args, in: repo, qos: qos)
  }

  static func exec(_ command: [String], in dir: URL, config: String? = nil, qos: QualityOfService = .userInitiated) async -> (
    Int32, String
  ) {
    var env = ProcessInfo.processInfo.environment
    env.removeValue(forKey: "CLAUDE_CONFIG_DIR")
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if let config, config != "\(home)/.claude" { env["CLAUDE_CONFIG_DIR"] = config }
    let (code, out) = await spawn(command, in: dir, env: env, errors: true, qos: qos)
    return (code, String(decoding: out, as: UTF8.self))
  }

  static func spawn(_ command: [String], in dir: URL?, env: [String: String], errors: Bool, qos: QualityOfService) async -> (
    Int32, Data
  ) {
    var env = env
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = command
    if let dir { p.currentDirectoryURL = dir }
    p.environment = env
    p.qualityOfService = qos
    let pipe = Pipe()
    p.standardInput = FileHandle.nullDevice
    p.standardOutput = pipe
    p.standardError = errors ? pipe : FileHandle.nullDevice
    return await withCheckedContinuation { cont in
      let sink = Sink { cont.resume(returning: $0) }
      sink.held = p
      pipe.fileHandleForReading.readabilityHandler = { h in
        let data = h.availableData
        guard data.isEmpty else { return sink.append(data) }
        h.readabilityHandler = nil
        _ = pipe
        sink.ended()
      }
      p.terminationHandler = { p in
        sink.exited(p.terminationStatus)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { sink.ended() }
      }
      do {
        try p.run()
      } catch {
        pipe.fileHandleForReading.readabilityHandler = nil
        sink.failed(error.localizedDescription)
      }
    }
  }

  private final class Sink: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var status: Int32?
    private var closed = false
    private var finish: (((Int32, Data)) -> Void)?
    var held: AnyObject?

    init(_ finish: @escaping ((Int32, Data)) -> Void) { self.finish = finish }

    func append(_ chunk: Data) {
      lock.withLock { if finish != nil { data.append(chunk) } }
    }

    func exited(_ code: Int32) { settle { status = code } }

    func ended() { settle { closed = true } }

    func failed(_ why: String) {
      settle {
        data = Data(why.utf8)
        status = -1
        closed = true
      }
    }

    private func settle(_ change: () -> Void) {
      lock.lock()
      change()
      guard closed, let status, let done = finish else { return lock.unlock() }
      finish = nil
      held = nil
      let out = data
      data = Data()
      lock.unlock()
      done((status, out))
    }
  }
}

@MainActor
final class Flight {
  private var current: Task<Void, Never>?
  private var again = false
  private(set) var at = Date.distantPast

  var busy: Bool { current != nil }

  func run(within: Double = 0, _ work: @escaping @MainActor () async -> Void) async {
    if let current {
      if within <= 0 { again = true }
      return await current.value
    }
    guard within <= 0 || Date().timeIntervalSince(at) >= within else { return }
    let task = Task { @MainActor in
      repeat {
        again = false
        await work()
        at = Date()
      } while again
      current = nil
    }
    current = task
    await task.value
  }
}

@MainActor
final class Saver {
  private let delay: Duration
  private let write: (Data) -> Void
  private var last: Data?
  private var make: (() -> Data?)?
  private var timer: Task<Void, Never>?

  init(delay: Duration = .seconds(2), last: Data? = nil, write: @escaping (Data) -> Void) {
    self.delay = delay
    self.last = last
    self.write = write
  }

  func save(_ make: @escaping () -> Data?) {
    self.make = make
    guard timer == nil else { return }
    timer = Task { [weak self, delay] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled else { return }
      self?.flush()
    }
  }

  func flush() {
    timer?.cancel()
    timer = nil
    guard let make else { return }
    self.make = nil
    guard let data = make(), data != last else { return }
    last = data
    write(data)
  }
}

@MainActor @Observable
final class Store {
  let paths: Paths
  let defaults: UserDefaults
  let ci = CI()
  let planner: Planner
  let directions: Directions
  let suggestions: GoalIdeas
  let goalDraft = GoalDraft()
  let handoffs = Handoffs()
  let health = Health()
  let recall: Recall

  var specs: [LoopSpec] = []
  var project: ProjectConfig?
  var states: [String: LoopState] = [:]
  var briefs: [Brief] = []
  var running: [String: Date] = [:]
  var paused: Set<String> = []
  var descriptions: [String: String] = [:]
  var lessons: [String: [String]] = [:]
  var latest: [String: Brief] = [:]
  var asks: [Ask] = []
  var forecast: [Tick] = []
  var nextRun: [String: Date] = [:]
  var nextTick = Date()
  var now = Date()
  var models: [String: String] = [:]
  var live: LiveTick?
  var spend = SpendReport()
  var runsByLoop: [String: [RunStat]] = [:]
  var spentByTask: [String: Tokens] = [:]
  var verdicts: [Int: String] = [:]
  var reviewedAt: [Int: Date] = [:]
  var askedAt: [String: Date] = [:]
  var modelPRs: [String: ModelPR] = [:]
  var watched: Set<String> = []
  var starting: [String: Date] = [:]
  var tasks: [BgTask] = []
  var asking: Set<String> = []
  var started: [String: String] = [:]
  let jobs: JobWatcher
  let configs: [String]
  var editing: LoopEdit?
  var proposed: LoopChange?
  var merges: [PullRequest] = []
  var queued: [String: String] = [:]
  var changes: [String: ChangeStatus] = [:]
  var notifyAll = UserDefaults.standard.bool(forKey: "notifyAll")
  @ObservationIgnored private var watch: FileWatch?
  @ObservationIgnored private var reloading = false
  @ObservationIgnored private var reloadAgain = false
  @ObservationIgnored private var liveSoon: Task<Void, Never>?
  @ObservationIgnored private var spendSoon: Task<Void, Never>?
  @ObservationIgnored var hooked: Set<String> = []
  @ObservationIgnored var heard = Date.distantPast
  @ObservationIgnored var announced: Set<Int>?
  @ObservationIgnored private var loops: [Task<Void, Never>] = []
  @ObservationIgnored private var observers: [NSObjectProtocol] = []
  @ObservationIgnored private var ran: [Feed: Date] = [:]
  @ObservationIgnored private var stopped = false
  @ObservationIgnored private let owned: Bool
  @ObservationIgnored private let probes = NSHashTable<VisibilityProbe>.weakObjects()
  @ObservationIgnored private var inboxGeneration = 0
  @ObservationIgnored var derivation = 0
  @ObservationIgnored var checked: Set<String> = []
  @ObservationIgnored var numbers: [String: (links: [String], answer: String?, found: [Int])] = [:]
  @ObservationIgnored private var hasScript: Bool?
  @ObservationIgnored let saver: Saver
  @ObservationIgnored let runnerFlight = Flight()
  @ObservationIgnored let githubFlight = Flight()
  @ObservationIgnored let liveFlight = Flight()
  @ObservationIgnored let spendFlight = Flight()
  @ObservationIgnored let inputFlight = Flight()
  @ObservationIgnored private let allFlight = Flight()

  var open: Set<Int>?
  var githubLoaded = false

  var runnerLoaded: Bool { runner != nil || runnerProblem != nil }
  var pulls: [Int: PullRequest] = [:]
  var issues: [Int: Issue] = [:]
  var items: [Item] = []
  var outcomes: [Outcome] = []
  var nextUp: [String: [String]] = [:]
  var merging: Set<Int> = []
  var mergedNow: Set<Int> = []
  var runner: RunnerState?
  var limit: UsageLimit?
  var runnerProblem: String?
  var action: String?
  var notice: String?
  var retry: [String]?
  var page: Page? = .home
  var inboxSelection: String?
  var composing = false
  var appearance: Appearance
  private(set) var dismissed: Set<String>
  private(set) var inbox: [InboxRow] = []
  var inputs: [String: PendingInput] = [:]
  var reviewed: [String: String] = [:]

  init(repo: URL, defaults: UserDefaults, jobs shared: JobWatcher? = nil) {
    paths = Paths(repo: repo)
    self.defaults = defaults
    planner = Planner(defaults: defaults)
    directions = Directions(defaults: defaults)
    suggestions = GoalIdeas(defaults: defaults)
    recall = Recall(defaults: defaults)
    queued = defaults.dictionary(forKey: "queuedFollowUps") as? [String: String] ?? [:]
    dismissed = Set(defaults.stringArray(forKey: "dismissed") ?? [])
    appearance = Appearance(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .system
    saver = Saver(last: defaults.data(forKey: "tasks")) { [defaults] in defaults.set($0, forKey: "tasks") }
    configs = Store.accounts(repo)
    owned = shared == nil
    jobs = shared ?? JobWatcher(configs: configs)
    loadTasks()
    loadModelPRs()
    if owned {
      jobs.start()
      Task { await jobs.reconcile() }
    }
    let center = NotificationCenter.default
    observers.append(
      center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.activate() }
      })
    observers.append(
      center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.saver.flush() }
      })
    DispatchQueue.main.async { [weak self, appearance] in
      NSApp.appearance = appearance.nsAppearance
      self?.trackBadge()
    }
    followJobs()
    rebuildInbox()
    ran[.spend] = Date().addingTimeInterval(30 - interval(.spend))
    loops.append(
      Task { [weak self] in
        while !Task.isCancelled {
          guard self?.check() != nil else { return }
          try? await Task.sleep(for: .seconds(5))
        }
      })
  }

  static func accounts(_ repo: URL) -> [String] {
    let legacy = (Reader.text(repo.appending(path: ".git/loop-accounts")) ?? "").split(separator: "\n").map(String.init)
    return Array(Set((legacy + (Registry.read()?.accounts ?? [])).map { ($0 as NSString).expandingTildeInPath })).sorted()
  }

  func stop() {
    guard !stopped else { return }
    stopped = true
    loops.forEach { $0.cancel() }
    loops = []
    liveSoon?.cancel()
    spendSoon?.cancel()
    observers.forEach(NotificationCenter.default.removeObserver)
    observers = []
    watch?.stop()
    watch = nil
    if owned { jobs.stop() }
    saver.flush()
  }

  enum Feed: CaseIterable { case tick, runner, live, spend, github, ci }

  var visible: Bool { probes.allObjects.contains(where: \.shown) }

  func track(_ probe: VisibilityProbe) {
    if !probes.contains(probe) { probes.add(probe) }
  }

  func sighted() { check() }

  private var hooksLive: Bool { Date().timeIntervalSince(heard) < 2 * 3600 }

  func interval(_ feed: Feed) -> Double {
    switch feed {
    case .tick, .live: 60
    case .runner: hooksLive ? 300 : 60
    case .spend: visible ? 60 : 600
    case .github: visible ? 300 : 600
    case .ci: visible ? 60 : 300
    }
  }

  private func check() {
    guard !stopped else { return }
    let now = Date()
    for feed in Feed.allCases where now.timeIntervalSince(ran[feed] ?? .distantPast) >= interval(feed) {
      ran[feed] = now
      Task { await run(feed) }
    }
  }

  private func run(_ feed: Feed) async {
    switch feed {
    case .tick:
      clock(Date())
      startWatching()
      reload()
      refreshTasks()
      planner.wake(store: self)
    case .runner: await refreshRunner(within: 1)
    case .live: await refreshLive(within: 1)
    case .spend: await refreshSpend(within: 1)
    case .github: await refreshGitHub(within: 1)
    case .ci: await ci.refreshIfStale(store: self, after: interval(.ci) - 15)
    }
  }

  private func activate() {
    guard !stopped, visible else { return }
    Task { await refreshGitHub(within: 20) }
  }

  private var runnerProjects: [String] { configs.map { "\($0)/projects/\(Spend.slug(paths.runner.path))" } }

  private func startWatching() {
    if watch == nil {
      watch = FileWatch { [weak self] changed in MainActor.assumeIsolated { self?.changed(changed) } }
    }
    let home = [paths.loops, paths.runner.appending(path: ".claude/workflows"), paths.runner.appending(path: ".claude/agents"), paths.locks]
    watch?.start(home.map(\.path) + runnerProjects, latency: 0.5)
  }

  private func changed(_ files: [String]) {
    let projects = runnerProjects
    let reporters = files.map { Lifecycle.reporter(of: $0, in: projects) }
    if reporters.contains(nil) { reload() }
    guard reporters.contains(where: { $0.map { !hooked.contains($0) } ?? false }) else { return }
    liveLater(1.5)
    spendLater()
  }

  func liveLater(_ delay: Double) {
    guard liveSoon == nil, !stopped else { return }
    liveSoon = Task { [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled else { return }
      self?.liveSoon = nil
      await self?.refreshLive()
    }
  }

  func spendLater() {
    guard spendSoon == nil, !stopped, visible else { return }
    spendSoon = Task { [weak self] in
      try? await Task.sleep(for: .seconds(15))
      guard !Task.isCancelled else { return }
      self?.spendSoon = nil
      await self?.refreshSpend()
    }
  }

  func handle(action: String, task: String?, pr: Int?, text: String?) {
    switch action {
    case "reply":
      if let task, let t = self.task(stable: task), let text { reply(t, text) }
    case "merge":
      if let pr, let p = pulls[pr], mergeState(p).mergeable { merge(p) }
    default:
      if let task {
        page = .task(task)
      } else if let pr {
        inboxSelection = "pr-\(pr)"
        page = .inbox
      }
      Workspace.current?.show(id)
    }
  }

  func announce() {
    rebuildInbox()
    let ready = Set(inbox.filter { $0.kind == .merge }.compactMap(\.pr))
    defer { if !pulls.isEmpty { announced = ready } }
    guard let announced else { return }
    for n in ready.subtracting(announced) {
      guard let p = pulls[n] else { continue }
      notify(
        title: "#\(n) is ready to merge", body: p.oneWay ? "\(p.tidyTitle)\nOne-way door: hard to undo." : p.tidyTitle,
        category: Notify.ready, info: ["pr": n])
    }
  }

  private func trackBadge() {
    let count = withObservationTracking {
      inbox.count
    } onChange: { [weak self] in
      Task { @MainActor in self?.trackBadge() }
    }
    NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
  }

  private func followJobs() {
    guard !stopped else { return }
    withObservationTracking {
      _ = jobs.jobs
    } onChange: { [weak self] in
      Task { @MainActor in
        self?.refreshTasks()
        self?.followJobs()
      }
    }
  }

  func rebuildInbox() {
    inboxGeneration += 1
    let generation = inboxGeneration
    let rows = withObservationTracking {
      inboxRows()
    } onChange: { [weak self] in
      Task { @MainActor in
        guard let self, !self.stopped, self.inboxGeneration == generation else { return }
        self.rebuildInbox()
      }
    }
    if rows != inbox { inbox = rows }
  }

  private func clock(_ date: Date) {
    if Int(date.timeIntervalSince1970 / 60) != Int(now.timeIntervalSince1970 / 60) { now = date }
  }

  @discardableResult
  func update<T: Equatable>(_ key: ReferenceWritableKeyPath<Store, T>, _ value: T) -> Bool {
    guard self[keyPath: key] != value else { return false }
    self[keyPath: key] = value
    return true
  }

  func refreshSpend(within: Double = 0) async {
    await spendFlight.run(within: within) { await self.loadSpend() }
  }

  private func loadSpend() async {
    let configs = configs
    let runner = paths.runner
    let tasks = tasks.compactMap { t in t.sessionId.flatMap { sid in t.cwd.map { (session: sid, cwd: $0) } } }
    let keyed = self.tasks.compactMap { t in t.sessionId.flatMap { sid in t.cwd.map { (id: t.stable, session: sid, cwd: $0) } } }
    let (report, spent) = await Task.detached(priority: .utility) {
      let report = Spend.report(configs: configs, runner: runner, tasks: tasks, now: Date())
      var spent: [String: Tokens] = [:]
      for t in keyed {
        let total = configs.map { Spend.agent(URL(fileURLWithPath: $0).appending(path: "projects/\(Spend.slug(t.cwd))/\(t.session).jsonl")).tokens }
          .reduce(Tokens(), +)
        if !total.isEmpty { spent[t.id] = total }
      }
      return (report, spent)
    }.value
    if report != spend {
      spend = report
      runsByLoop = Dictionary(grouping: report.runs, by: \.loop)
    }
    update(\.spentByTask, spent)
  }

  func taskSpend(_ t: BgTask) -> Tokens? { spentByTask[t.stable] }

  func perf(_ loop: String) -> LoopPerf { LoopPerf(loop: loop, title: title(loop), runs: runsByLoop[loop] ?? []) }

  func advice(_ loop: String) -> [Advice] { perf(loop).advice(model: models[loop] ?? "inherit") }

  var topAdvice: [Advice] {
    specs.flatMap { advice($0.name) }.filter { ($0.saving ?? 0) >= 0.5 }.sorted { ($0.saving ?? 0) > ($1.saving ?? 0) }
  }

  var fixedContext: (tokens: Int, agents: Int, cost: Double, read: Int) {
    let runs = spend.runs.filter { $0.startup > 0 }
    return (
      Int(LoopPerf.median(runs.map { Double($0.startup) })), runs.map(\.agents).reduce(0, +), runs.map(\.fixed).reduce(0, +),
      runs.map(\.fixedTokens).reduce(0, +)
    )
  }

  var fixedAdvice: Advice? {
    let f = fixedContext
    let week = spend.week.cost
    guard f.agents > 0, week > 0, f.cost / week >= 0.15 else { return nil }
    let pct = Int(f.cost / week * 100)
    return Advice(
      id: "fixed", loop: nil, symbol: "doc.text.magnifyingglass",
      title: "Setup is \(pct)% of loop spend",
      detail:
        "Each agent starts with \(f.tokens.compact) tokens of prompts, tools and skills, and re-reads them every turn. \(f.agents) agents this week: \(f.cost.usd).",
      saving: nil, badge: "\(f.read.compact) tokens read · \(f.cost.usd)/wk",
      action: .ask(
        "Ask Claude to trim it",
        prompt:
          "Every loop agent in this repo starts with about \(f.tokens.compact) tokens of fixed context before its first step and re-reads it on every turn; across \(f.agents) agents in the last 7 days that came to \(f.cost.usd) at API prices, \(pct)% of loop spend. Loop agents come from the loops plugin (`loop-runner kit` prints where it lives) and the repo's .claude/agents/loop-*.md, and run as subagents of the runner's tick workflow. Find what makes up that context (system prompt, tool list, the skill listing, CLAUDE.md, AGENTS.md and what they import) and cut what the loop agents don't need, without changing what the loops do. Measure a loop agent's first-turn context before and after. Open a pull request.",
        done: Goal.pullRequest
      ))
  }

  func refreshLive(within: Double = 0) async {
    await liveFlight.run(within: within) { await self.loadLive() }
  }

  private func loadLive() async {
    let config = runner?.account ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude").path
    let runner = paths.runner
    let now = Date()
    let locked = Set(running.keys)
    let next = await Task.detached(priority: .utility) { Live.read(config: config, runner: runner, running: locked, now: now) }.value
    let before = Set(live?.agents.filter { !$0.finished && !$0.stalled }.map(\.loop) ?? [])
    let after = Set(next?.agents.filter { !$0.finished && !$0.stalled }.map(\.loop) ?? [])
    if next != live { live = next }
    for loop in before.subtracting(after) where notifyAll || watched.contains(loop) {
      if watched.contains(loop) { watched.remove(loop) }
      let brief = next?.agents(for: loop).first { $0.role == nil }?.brief
      let line = brief.map { Briefs.readable(Briefs.sentences(Briefs.body(Brief(id: 0, at: now, loop: loop, text: $0))).first ?? $0) }
      notify(title: "\(title(loop)) finished", body: line ?? "Its run is over. Open Loops for the brief.")
    }
  }

  func runNow(_ loop: String) {
    guard running[loop] == nil, starting[loop] == nil else {
      notice = "\(title(loop)) is already running."
      return
    }
    starting[loop] = Date()
    launch("/\(loop)", name: "\(title(loop)) (run now)", loop: loop, in: paths.runner, worktree: nil, key: "run:\(loop)") { ok in
      if !ok { self.starting[loop] = nil }
      self.reload()
      Task { await self.refreshLive() }
    }
  }

  func isStarting(_ loop: String) -> Bool {
    guard let at = starting[loop] else { return false }
    return running[loop] == nil && now.timeIntervalSince(at) < 180
  }

  func toggleWatch(_ loop: String) {
    if watched.contains(loop) {
      watched.remove(loop)
    } else {
      watched.insert(loop)
      Task { await Notify.authorize() }
    }
  }

  var notifyAllBinding: Binding<Bool> {
    Binding(
      get: { self.notifyAll },
      set: { on in
        if let w = Workspace.current { w.setNotifyAll(on) } else { self.notifyAll = on }
      })
  }

  func reload() {
    guard !reloading else {
      reloadAgain = true
      return
    }
    reloading = true
    let paths = paths
    let known = descriptions
    let date = Date()
    Task {
      let snap = await Task.detached(priority: .utility) { LoopSnapshot.read(paths: paths, descriptions: known, now: date) }.value
      apply(snap, at: date)
      reloading = false
      if reloadAgain {
        reloadAgain = false
        reload()
      }
    }
  }

  private func apply(_ snap: LoopSnapshot, at date: Date) {
    clock(date)
    if update(\.specs, snap.specs) {
      Briefs.names = Dictionary(uniqueKeysWithValues: specs.map { ($0.name, $0.title) })
      Symbols.custom = Dictionary(uniqueKeysWithValues: specs.compactMap { s in s.symbol.map { (s.name, $0) } })
      LoopsShortcuts.updateAppShortcutParameters()
    }
    update(\.project, snap.project)
    update(\.models, snap.models)
    if update(\.states, snap.states) {
      update(\.reviewed, (snap.states["loop-pr-review"]?.raw["reviewed"] as? [String: String]) ?? [:])
    }
    let newBriefs = update(\.briefs, snap.briefs)
    update(\.running, snap.running)
    update(\.paused, snap.paused)
    update(\.descriptions, snap.descriptions)
    update(\.lessons, snap.lessons)
    var latest: [String: Brief] = [:]
    for b in briefs where latest[b.loop].map({ b.at >= $0.at }) ?? true { latest[b.loop] = b }
    update(\.latest, latest)
    let newAsks = settle()
    update(\.nextTick, snap.nextTick)
    update(\.forecast, snap.forecast)
    update(\.nextRun, snap.nextRun)
    if newBriefs || newAsks || items.isEmpty { derive() }
  }

  @discardableResult
  func settle() -> Bool {
    update(\.asks, latest.values.sorted { $0.at > $1.at }.flatMap(Briefs.asks).filter { !dismissed.contains($0.id) && !settled($0) })
  }

  func refresh() async {
    reload()
    async let runner: Void = refreshRunner(within: 20)
    async let github: Void = refreshGitHub(within: 20)
    async let checks: Void = ci.refreshIfStale(store: self)
    _ = await (runner, github, checks)
  }

  func refreshAll() async {
    await allFlight.run {
      self.reload()
      async let runner: Void = self.refreshRunner()
      async let github: Void = self.refreshGitHub()
      async let checks: Void = self.ci.refresh(store: self)
      async let spend: Void = self.refreshSpend()
      async let live: Void = self.refreshLive()
      _ = await (runner, github, checks, spend, live)
    }
  }

  private func settled(_ ask: Ask) -> Bool {
    guard let open else { return false }
    let named = Set(Briefs.numbers(ask.text + " " + (ask.url?.absoluteString.removingPercentEncoding ?? "")))
    return !named.isEmpty && named.isDisjoint(with: open)
  }

  private var script: URL? {
    if hasScript == nil { hasScript = (Reader.text(paths.script) ?? "").contains("  state) state ;;") }
    return hasScript == true ? paths.script : nil
  }

  func refreshRunner(within: Double = 0) async {
    await runnerFlight.run(within: within) { await self.loadRunner() }
  }

  private func loadRunner() async {
    guard let script else {
      update(\.runner, nil)
      update(\.runnerProblem, "This build of Loops has no loop-runner, so the runner's status and account are unknown.")
      return
    }
    let (code, out) = await Shell.run(script, ["state"], in: paths.repo, qos: .utility)
    let json = out.split(separator: "\n").last.map(String.init) ?? ""
    if code == 0, let s = try? JSONDecoder().decode(RunnerState.self, from: Data(json.utf8)) {
      update(\.runner, s)
      update(\.runnerProblem, nil)
      let runner = paths.runner
      let job = s.session?.id.flatMap { jobs.jobs[$0] }
      let stuck = s.session?.state == "blocked" ? job?.detail.flatMap { $0.localizedCaseInsensitiveContains("limit") ? $0 : nil } : nil
      let next =
        s.limited
        ? await Task.detached { UsageLimit.read(config: s.account, runner: runner) }.value ?? limit
        : stuck.map { UsageLimit(text: $0, at: job?.updated, resets: UsageLimit.resets(in: $0, after: job?.updated ?? Date())) }
      if next != limit { noticeLimit(from: limit, to: next) }
    } else {
      update(\.runnerProblem, out.isEmpty ? "loop-runner state exited with \(code)." : out)
    }
  }

  func enabled(_ name: String) -> Binding<Bool> {
    Binding(get: { !self.paused.contains(name) }, set: { self.setEnabled(name, $0) })
  }

  func setEnabled(_ name: String, _ on: Bool) {
    perform(on ? "Enabling \(title(name))…" : "Disabling \(title(name))…", [on ? "unpause" : "pause", name])
  }

  func perform(_ label: String, _ args: [String]) {
    guard let script, action == nil else { return }
    action = label
    notice = nil
    retry = nil
    Task {
      let (code, out) = await Shell.run(script, args, in: paths.repo)
      action = nil
      let text = out.trimmingCharacters(in: .whitespacesAndNewlines)
      if code != 0 {
        notice = text.isEmpty ? "\(args.joined(separator: " ")) exited with \(code)." : text
        if text.contains("--force") && !args.contains("--force") { retry = args + ["--force"] }
      }
      reload()
      await refreshRunner()
    }
  }

  func terminal(_ lines: [String]) {
    let file = FileManager.default.temporaryDirectory.appending(path: "loops-\(UUID().uuidString).command")
    let body = (["#!/bin/bash", "cd \(quoted(paths.runner.path)) 2>/dev/null || cd \(quoted(paths.repo.path))"] + lines).joined(separator: "\n") + "\n"
    guard (try? body.write(to: file, atomically: true, encoding: .utf8)) != nil else { return }
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    NSWorkspace.shared.open(file)
  }

  func attach() {
    guard let script else { return }
    terminal(["exec bash \(quoted(script.path)) attach"])
  }

  func addAccount(own: Bool = false) {
    guard let script else { return }
    terminal(["bash \(quoted(script.path)) account add\(own ? " --own" : "")"])
  }

  private func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

  var loopGroups: [LoopGroup] {
    Dictionary(grouping: specs, by: { $0.group ?? "Other" })
      .map { name, loops in LoopGroup(name: name, loops: specs.filter { s in loops.contains(s) }) }
      .sorted { Groups.rank($0.name) < Groups.rank($1.name) }
  }

  func title(_ name: String) -> String { specs.first { $0.name == name }?.title ?? LoopSpec.short(name) }

  func setAppearance(_ a: Appearance) {
    if let w = Workspace.current { w.setAppearance(a) } else { appearance = a }
  }

  var id: String { paths.repo.path }
  var name: String { project?.name ?? paths.repo.lastPathComponent }

  func notify(title: String, body: String, category: String? = nil, info: [String: Any] = [:]) {
    let shared = (Workspace.current?.projects.count ?? 1) > 1
    Notify.post(title: shared ? "\(name): \(title)" : title, body: body, category: category, info: info.merging(["project": id]) { a, _ in a })
  }

  var appearanceBinding: Binding<Appearance> {
    Binding(get: { self.appearance }, set: { self.setAppearance($0) })
  }

  func dismiss(_ ask: Ask) {
    dismissed.insert(ask.id)
    defaults.set(Array(dismissed), forKey: "dismissed")
    asks.removeAll { $0.id == ask.id }
  }

  func restore(_ ids: [String]) {
    dismissed.subtract(ids)
    defaults.set(Array(dismissed), forKey: "dismissed")
  }

  var phase: Phase {
    guard let r = runner else { return .unknown }
    guard let s = r.session else { return .stopped }
    if r.limited || (limit != nil && s.state == "blocked") { return .limited }
    if let w = s.waitingFor { return .blocked("waiting for \(w)") }
    if let state = s.state, state == "blocked" || state == "failed" { return .blocked(state) }
    return running.isEmpty ? .idle : .working
  }

  var account: RunnerState.Account? {
    guard let r = runner else { return nil }
    return r.accounts.first { $0.dir == r.account } ?? .init(dir: r.account, email: nil, limitedAt: nil, limit: nil, own: nil)
  }

  func rested(_ a: RunnerState.Account) -> Bool {
    guard let t = a.limitedAt else { return true }
    return now.timeIntervalSince1970 - t >= 3600
  }

  func kind(_ l: LoopSpec) -> Standing {
    if running[l.name] != nil { return .running }
    if paused.contains(l.name) { return .off }
    if !Schedule.inHours(l, at: now) { return .outside }
    return Schedule.due(l, last: states[l.name]?.at, at: now) ? .due : .resting
  }

  var headline: String {
    switch phase {
    case .working: running.count == 1 ? "1 loop working" : "\(running.count) loops working"
    case .idle: "All quiet until \(Clock.time(nextTick))"
    case .limited:
      if limitLifted { "Ready to resume" } else if let r = limit?.resets { r > Date() ? "Paused until \(Clock.day(r, now: now))" : "Back at the next tick, \(Clock.time(nextTick))" } else { "At the usage limit" }
    case .stopped: "The runner is stopped"
    case .blocked: "The runner needs you"
    case .unknown: running.isEmpty ? "Runner status unknown" : "\(running.count) loops working"
    }
  }

  var sentence: String {
    let unbroken = { (s: String) in s.replacingOccurrences(of: " ", with: "\u{00A0}") }
    let names = running.sorted { $0.value < $1.value }.map { unbroken(title($0.key)) }
    let upcoming =
      forecast.first.map { "About \(Clock.time($0.at)), the runner picks up \(joined($0.runs.map { unbroken($0.title) }))." }
      ?? ""
    switch phase {
    case .stopped:
      return "The runner is stopped. Nothing runs until you start it."
    case .limited:
      let who = account?.email ?? "This account"
      let kind = limit?.kind ?? "usage limit"
      if let r = limit?.resets, r <= Date() {
        return "\(who) hit its \(kind), which reset at \(Clock.time(r)). The runner picks the loops up again at its next tick, \(Clock.time(nextTick))."
      }
      let resets = limit?.resets.map { ", back at \(Clock.day($0, now: now))" } ?? Briefs.resets(account?.limit).map { ", \($0)" } ?? ""
      let others = (runner?.accounts ?? []).filter { $0.dir != runner?.account && $0.email != nil }
      if let next = others.first(where: rested), let email = next.email {
        return "\(who) hit its \(kind)\(resets). The runner moves to \(email) at its next check, within five minutes."
      }
      if others.isEmpty {
        return "\(who) hit its \(kind)\(resets). Loops wait until it resets; add a second account to keep them going."
      }
      return "Every account is at its usage limit\(resets). Loops wait until one resets."
    case .blocked(let why):
      return ["blocked", "failed"].contains(why)
        ? "The runner's session stopped and doesn't pick up new ticks on its own. Resume it, or open it in Terminal to see why."
        : "The runner is blocked: \(why). Resume it, or open it in Terminal to answer."
    default:
      let now = names.isEmpty ? "Nothing is running." : "\(joined(names)) \(names.count == 1 ? "is" : "are") working."
      return [now, upcoming].filter { !$0.isEmpty }.joined(separator: " ")
    }
  }
}
