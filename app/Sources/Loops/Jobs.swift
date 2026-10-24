import CoreServices
import Foundation
import Observation

struct Job: Identifiable, Equatable {
  let id: String
  var name: String
  var state: String
  var waitingFor: String?
  var detail: String?
  var result: String?
  var sessionId: String?
  var cwd: String?
  var worktreeBranch: String?
  var tasksDone: Int
  var tasksTotal: Int
  var current: String?
  var activity: [String]
  var plan: [PlanStep] = []
  var updated: Date
  var transcript: String? = nil
  var prs: [String] = []
}

@MainActor @Observable
final class JobWatcher {
  private(set) var jobs: [String: Job] = [:]
  @ObservationIgnored private let source: JobSource
  @ObservationIgnored private var stream: FSEventStreamRef?
  @ObservationIgnored private var watched: [String] = []
  @ObservationIgnored private var followed: String?
  @ObservationIgnored private var hooked: Set<String> = []

  init(configs: [String]) {
    var seen = Set<String>()
    source = JobSource(configs: configs.map(JobSource.standard).filter { seen.insert($0).inserted })
    source.watcher = self
  }

  func start() {
    guard stream == nil else { return }
    let source = self.source
    source.queue.async { source.rescan() }
    open()
  }

  func stop() {
    close()
    followed = nil
    let source = self.source
    source.queue.async { source.follow(nil) }
  }

  func follow(_ id: String?) {
    guard id != followed else { return }
    followed = id
    let source = self.source
    source.queue.async { source.follow(id) }
  }

  func reconcile() async {
    for config in source.configs {
      guard let data = await JobSource.output(["claude", "agents", "--json", "--all"], config: config),
        let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
      else { continue }
      for entry in list {
        guard let id = entry["id"] as? String else { continue }
        let state = entry["state"] as? String
        if var job = jobs[id] {
          if let state { job.state = state }
          job.waitingFor = entry["waitingFor"] as? String
          if let name = entry["name"] as? String { job.name = name }
          if job != jobs[id] { jobs[id] = job }
        } else if (entry["kind"] as? String) == "background" {
          let loaded = await source.load(id: id, config: config)
          var job =
            loaded
            ?? Job(
              id: id, name: entry["name"] as? String ?? id, state: state ?? "unknown", waitingFor: nil, detail: nil,
              result: nil, sessionId: entry["sessionId"] as? String, cwd: entry["cwd"] as? String, worktreeBranch: nil,
              tasksDone: 0, tasksTotal: 0, current: nil, activity: [],
              updated: (entry["startedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date())
          if let state { job.state = state }
          job.waitingFor = entry["waitingFor"] as? String
          jobs[id] = job
        }
      }
    }
    if source.watchPaths() != watched {
      close()
      open()
    }
  }

  fileprivate func apply(_ changed: [Job], removed: [String], all: Bool) {
    var next = all ? [:] : jobs
    for id in removed { next[id] = nil }
    for var job in changed {
      if let old = jobs[job.id] {
        job.activity = old.activity
        if job.waitingFor == nil, job.state == "blocked", old.state == "blocked" { job.waitingFor = old.waitingFor }
      }
      next[job.id] = job
    }
    if next != jobs { jobs = next }
  }

  func record(_ tool: String, _ input: [String: Any], for id: String) {
    hooked.insert(id)
    guard var job = jobs[id], let step = JobTail.step(tool, input) else { return }
    job.activity = Array((job.activity + [String(step.prefix(90))]).suffix(8))
    jobs[id] = job
  }

  fileprivate func steps(_ steps: [String], for id: String, reset: Bool) {
    guard var job = jobs[id], reset || !hooked.contains(id) else { return }
    job.activity = Array(((reset ? [] : job.activity) + steps).suffix(8))
    if job != jobs[id] { jobs[id] = job }
  }

  private func open() {
    let paths = source.watchPaths()
    watched = paths
    guard !paths.isEmpty else { return }
    var context = FSEventStreamContext(
      version: 0, info: Unmanaged.passUnretained(source).toOpaque(), retain: nil, release: nil, copyDescription: nil)
    let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
      guard let info else { return }
      let source = Unmanaged<JobSource>.fromOpaque(info).takeUnretainedValue()
      let list = (Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray) as? [String] ?? []
      let scan = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged)
      let rescan = (0..<count).contains { flags[$0] & scan != 0 }
      source.changed(list, rescan: rescan)
    }
    let flags = FSEventStreamCreateFlags(
      kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
    guard
      let made = FSEventStreamCreate(
        nil, callback, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags)
    else { return }
    FSEventStreamSetDispatchQueue(made, source.queue)
    FSEventStreamStart(made)
    stream = made
  }

  private func close() {
    guard let stream else { return }
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
    self.stream = nil
    watched = []
  }
}

private final class JobSource: @unchecked Sendable {
  let configs: [String]
  let queue = DispatchQueue(label: "io.github.korabh.loops.jobs", qos: .utility)
  weak var watcher: JobWatcher?
  private var homes: [String: String] = [:]
  private var sessions: [String: String] = [:]
  private var transcripts: [String: String] = [:]
  private var followed: String?
  private var tail: JobTail?

  init(configs: [String]) { self.configs = configs }

  static func standard(_ path: String) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    guard let real = realpath(expanded, nil) else { return (expanded as NSString).standardizingPath }
    defer { free(real) }
    return String(cString: real)
  }

  func watchPaths() -> [String] {
    configs.flatMap { ["\($0)/jobs", "\($0)/tasks"] }.filter { FileManager.default.fileExists(atPath: $0) }
  }

  func rescan() {
    var found: [Job] = []
    for config in configs {
      let dir = "\(config)/jobs"
      for id in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where !id.contains(".") {
        if case .job(let job) = read(id: id, config: config) { found.append(job) }
      }
    }
    post(found, removed: [], all: true)
  }

  func changed(_ paths: [String], rescan: Bool) {
    if rescan { return self.rescan() }
    var targets: [String: String] = [:]
    for path in paths {
      for config in configs where path.hasPrefix(config + "/") {
        let rest = path.dropFirst(config.count + 1).split(separator: "/").map(String.init)
        guard rest.count >= 2, !rest[1].contains(".") else { continue }
        if rest[0] == "jobs" { targets[rest[1]] = config }
        if rest[0] == "tasks", let id = sessions["\(config)|\(rest[1])"] { targets[id] = config }
      }
    }
    var changed: [Job] = []
    var removed: [String] = []
    for (id, config) in targets {
      switch read(id: id, config: config) {
      case .job(let job): changed.append(job)
      case .missing: removed.append(id)
      case .unreadable: break
      }
    }
    if !changed.isEmpty || !removed.isEmpty { post(changed, removed: removed, all: false) }
  }

  func load(id: String, config: String) async -> Job? {
    await withCheckedContinuation { cont in
      queue.async {
        if case .job(let job) = self.read(id: id, config: config) { cont.resume(returning: job) } else { cont.resume(returning: nil) }
      }
    }
  }

  func follow(_ id: String?) {
    followed = id
    tail?.cancel()
    tail = nil
    guard let id, let path = transcripts[id] else { return }
    tail = JobTail(path: path, queue: queue) { [weak self] steps, reset in
      guard let watcher = self?.watcher else { return }
      DispatchQueue.main.async { MainActor.assumeIsolated { watcher.steps(steps, for: id, reset: reset) } }
    }
  }

  private enum Read {
    case job(Job)
    case missing
    case unreadable
  }

  private func read(id: String, config: String) -> Read {
    let file = "\(config)/jobs/\(id)/state.json"
    guard let data = FileManager.default.contents(atPath: file) else {
      homes[id] = nil
      transcripts[id] = nil
      return .missing
    }
    guard let s = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .unreadable }
    let session = s["sessionId"] as? String
    let output = s["output"]
    var job = Job(
      id: id, name: s["name"] as? String ?? id, state: s["state"] as? String ?? "unknown",
      waitingFor: s["waitingFor"] as? String, detail: s["detail"] as? String,
      result: (output as? [String: Any])?["result"] as? String ?? output as? String, sessionId: session,
      cwd: s["cwd"] as? String, worktreeBranch: s["worktreeBranch"] as? String, tasksDone: 0, tasksTotal: 0,
      current: nil, activity: [],
      updated: ((try? FileManager.default.attributesOfItem(atPath: file))?[.modificationDate] as? Date) ?? Date())
    job.prs = (s["children"] as? [[String: Any]] ?? []).filter { $0["kind"] as? String == "pr" }.compactMap { $0["href"] as? String }
    homes[id] = config
    if let session {
      sessions["\(config)|\(session)"] = id
      let tasks = Self.tasks(in: "\(config)/tasks/\(session)")
      job.tasksTotal = tasks.count
      job.tasksDone = tasks.filter { $0.status == "completed" }.count
      job.current = tasks.first { $0.status == "in_progress" }?.subject
      job.plan = tasks.map { PlanStep(id: $0.id, subject: $0.subject, status: $0.status, changed: $0.changed) }
      let place = (s["worktreePath"] as? String) ?? job.cwd
      let path =
        (s["linkScanPath"] as? String).flatMap { $0.hasSuffix(".jsonl") ? $0 : nil }
        ?? place.map { "\(config)/projects/\($0.replacingOccurrences(of: "[^A-Za-z0-9-]", with: "-", options: .regularExpression))/\(session).jsonl" }
      job.transcript = path
      if let path, transcripts[id] != path {
        transcripts[id] = path
        if followed == id { follow(id) }
      } else if followed == id, tail == nil {
        follow(id)
      }
    }
    return .job(job)
  }

  private static func tasks(in dir: String) -> [(id: Int, subject: String, status: String, changed: Date)] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
      .filter { $0.hasSuffix(".json") }
      .compactMap { name -> (id: Int, subject: String, status: String, changed: Date)? in
        let path = "\(dir)/\(name)"
        guard let data = FileManager.default.contents(atPath: path),
          let t = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let status = t["status"] as? String, status != "deleted"
        else { return nil }
        let id = Int(t["id"] as? String ?? String(name.dropLast(5))) ?? Int.max
        let changed = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date ?? .distantPast
        return (id, t["subject"] as? String ?? "", status, changed)
      }
      .sorted { $0.id < $1.id }
  }

  private func post(_ changed: [Job], removed: [String], all: Bool) {
    guard let watcher else { return }
    DispatchQueue.main.async { MainActor.assumeIsolated { watcher.apply(changed, removed: removed, all: all) } }
  }

  static func output(_ command: [String], config: String) async -> Data? {
    await withCheckedContinuation { cont in
      DispatchQueue.global(qos: .utility).async {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = command
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDE_CONFIG_DIR")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if config != standard("\(home)/.claude") { env["CLAUDE_CONFIG_DIR"] = config }
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        let pipe = Pipe()
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch {
          cont.resume(returning: nil)
          return
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        cont.resume(returning: p.terminationStatus == 0 ? data : nil)
      }
    }
  }
}

private final class JobTail {
  private let source: DispatchSourceFileSystemObject
  private let handle: FileHandle
  private let emit: ([String], Bool) -> Void
  private var offset: UInt64
  private var partial = Data()
  private var first = true
  private let mid: Bool

  init?(path: String, queue: DispatchQueue, emit: @escaping ([String], Bool) -> Void) {
    let fd = Darwin.open(path, O_EVTONLY)
    guard fd >= 0 else { return nil }
    guard let handle = FileHandle(forReadingAtPath: path) else {
      Darwin.close(fd)
      return nil
    }
    self.handle = handle
    self.emit = emit
    let size = (try? handle.seekToEnd()) ?? 0
    offset = size > 65_536 ? size - 65_536 : 0
    mid = offset > 0
    source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd, eventMask: [.extend, .write, .delete, .rename], queue: queue)
    source.setEventHandler { [weak self] in
      guard let self else { return }
      if !self.source.data.isDisjoint(with: [.delete, .rename]) { return self.cancel() }
      self.read()
    }
    source.setCancelHandler {
      Darwin.close(fd)
      try? handle.close()
    }
    source.resume()
    queue.async { [weak self] in self?.read() }
  }

  func cancel() {
    if !source.isCancelled { source.cancel() }
  }

  deinit { cancel() }

  private func read() {
    guard !source.isCancelled else { return }
    try? handle.seek(toOffset: offset)
    guard let data = try? handle.readToEnd(), !data.isEmpty else { return }
    offset += UInt64(data.count)
    var buffer = partial
    buffer.append(data)
    guard let end = buffer.lastIndex(of: 0x0A) else {
      partial = buffer
      return
    }
    partial = Data(buffer[buffer.index(after: end)...])
    var lines = buffer[..<end].split(separator: 0x0A, omittingEmptySubsequences: true)
    if first, mid, !lines.isEmpty { lines.removeFirst() }
    let steps = lines.flatMap { JobTail.steps(Data($0)) }
    let reset = first
    first = false
    if reset || !steps.isEmpty { emit(steps, reset) }
  }

  private static let marker = Data("\"tool_use\"".utf8)

  static func steps(_ line: Data) -> [String] {
    guard line.range(of: marker) != nil,
      let row = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
      row["type"] as? String == "assistant",
      let content = (row["message"] as? [String: Any])?["content"] as? [[String: Any]]
    else { return [] }
    return content.compactMap { item in
      guard item["type"] as? String == "tool_use", let name = item["name"] as? String else { return nil }
      return step(name, item["input"] as? [String: Any] ?? [:]).map { String($0.prefix(90)) }
    }
  }

  static func step(_ name: String, _ input: [String: Any]) -> String? {
    let file = (input["file_path"] as? String).map { ($0 as NSString).lastPathComponent }
    let text = { (key: String) in (input[key] as? String)?.split(separator: "\n").first.map(String.init) }
    switch name {
    case "Bash": return text("description") ?? text("command").map { "Running \($0)" }
    case "Read": return file.map { "Reading \($0)" }
    case "Edit", "MultiEdit": return file.map { "Editing \($0)" }
    case "Write": return file.map { "Writing \($0)" }
    case "NotebookEdit": return (input["notebook_path"] as? String).map { "Editing \(($0 as NSString).lastPathComponent)" }
    case "Grep": return text("pattern").map { "Searching for \($0)" }
    case "Glob": return text("pattern").map { "Finding \($0)" }
    case "Skill": return text("skill").map { "Using the \($0) skill" }
    case "Agent", "Task": return text("description").map { "Agent: \($0)" }
    case "WebFetch": return text("url").map { "Fetching \(URL(string: $0)?.host ?? $0)" }
    case "WebSearch": return text("query").map { "Searching the web for \($0)" }
    case "TaskCreate": return text("subject").map { "Planned: \($0)" }
    case "TaskUpdate", "TaskList", "TaskGet", "ToolSearch": return nil
    default:
      if name.hasPrefix("mcp__") {
        let parts = name.split(separator: "_", omittingEmptySubsequences: true)
        return parts.count >= 3 ? "\(parts[1]): \(parts.dropFirst(2).joined(separator: " "))" : name
      }
      return text("description") ?? text("name").map { "\(name) \($0)" } ?? name
    }
  }
}
