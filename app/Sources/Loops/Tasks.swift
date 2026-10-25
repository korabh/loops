import AppKit
import SwiftUI

struct BgTask: Identifiable, Codable, Equatable {
  let id: String
  let title: String
  let loop: String?
  let prompt: String
  let started: Date
  var state: String = "working"
  var waitingFor: String?
  var sessionId: String?
  var cwd: String?
  var steps: Int = 0
  var answer: String?
  var key: String?
  var goal: TaskGoal?
  var limit: UsageLimit?
  var resumes: Int?
  var prs: [String]?
  var origin: String?

  var stable: String { origin ?? id }

  func resumed(as id: String, resumes: Int?) -> BgTask {
    BgTask(id: id, title: title, loop: loop, prompt: prompt, started: started, key: key, goal: goal, resumes: resumes, origin: stable)
  }

  var active: Bool { state == "working" || state == "blocked" || waitingFor != nil }

  var succeeded: Bool { state == "done" && limit == nil && (goal == nil || goal?.verdict == .met) }

  var goalMet: Bool { goal?.verdict == .met }

  var running: Bool { active && !goalMet }

  var label: String {
    if limit != nil { return "Limit hit" }
    if needsYou { return "Needs you" }
    if let goal, state == "done" || goal.verdict == .met {
      switch goal.verdict {
      case .met?: return "Goal met"
      case .impossible?: return "Goal impossible"
      default: return "Goal not met"
      }
    }
    switch state {
    case "working": return "Working"
    case "done": return "Done"
    case "failed": return "Failed"
    case "stopped": return "Stopped"
    default: return state.capitalized
    }
  }
}

extension Store {
  var config: String {
    runner?.account ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude").path
  }

  func loadTasks() {
    guard let data = defaults.data(forKey: "tasks"),
      let saved = try? JSONDecoder().decode([BgTask].self, from: data)
    else { return }
    tasks = saved
  }

  func saveTasks() {
    saver.save { [weak self] in self.flatMap { try? JSONEncoder().encode($0.tasks) } }
  }

  static func prompt(from url: URL?) -> String? {
    guard let url, let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
    return comps.queryItems?.first { $0.name == "q" }?.value
  }

  func task(key: String) -> BgTask? { tasks.first { $0.key == key } }

  func ask(
    _ prompt: String, loop: String?, from source: String? = nil, done: String? = nil, then: (@MainActor (Bool) -> Void)? = nil
  ) {
    let stamp = DateFormatter()
    stamp.dateFormat = "yyyyMMdd-HHmm"
    let base = (loop ?? "ask").replacingOccurrences(of: "loop-", with: "")
    let head = prompt.replacingOccurrences(of: "\n", with: " ").prefix(40)
    launch(
      prompt, name: "\(loop.map(title) ?? "Loops"): \(head)", loop: loop, in: paths.repo,
      worktree: "\(base)-\(stamp.string(from: Date()))", key: source ?? prompt,
      goal: done.map { TaskGoal(done: $0, turns: Goal.turns) }, then: then)
  }

  func launch(
    _ prompt: String, name: String, loop: String?, in dir: URL, worktree: String?, key: String? = nil,
    goal: TaskGoal? = nil, then: (@MainActor (Bool) -> Void)? = nil
  ) {
    let key = key ?? prompt
    let command = goal.flatMap { Goal.command(prompt, goal: $0) }
    if !asking.contains(key) { asking.insert(key) }
    notice = nil
    Task {
      let (code, out) = await Shell.exec(
        ["claude", "--bg", "--name", name, "--permission-mode", "auto", "--append-system-prompt", Store.unattended] + hookArgs
          + (worktree.map { ["--worktree", $0] } ?? []) + [command ?? prompt],
        in: dir, config: config)
      asking.remove(key)
      let id = Reader.groups(#"backgrounded · ([0-9a-f]+)"#, in: out).first
      guard code == 0, let id else {
        notice = "Could not start Claude Code: \(out.trimmingCharacters(in: .whitespacesAndNewlines).suffix(300))"
        then?(false)
        return
      }
      tasks.insert(BgTask(id: id, title: name, loop: loop, prompt: prompt, started: Date(), key: key, goal: command == nil ? nil : goal), at: 0)
      started[key] = id
      saveTasks()
      Task { await Notify.authorize() }
      await jobs.reconcile()
      refreshTasks()
      then?(true)
    }
  }

  func refreshTasks() {
    var changed = false
    for i in tasks.indices {
      guard let job = jobs.jobs[tasks[i].id] else { continue }
      let before = tasks[i]
      var t = before
      t.state = job.state
      t.waitingFor = job.waitingFor
      t.sessionId = job.sessionId ?? t.sessionId
      t.cwd = job.cwd ?? t.cwd
      t.answer = job.result ?? t.answer
      if !job.prs.isEmpty { t.prs = job.prs }
      t.goal = goalProgress(t)
      if job.state == "blocked", let detail = job.detail, UsageLimit.reached(detail) {
        t.limit = t.limit ?? UsageLimit(text: detail, at: Date(), resets: UsageLimit.resets(in: detail, after: Date()))
      } else if t.active {
        t.limit = nil
      } else if before.active {
        t.limit = t.limit ?? taskLimit(t)
      }
      guard t != before else { continue }
      tasks[i] = t
      changed = true
      if t.limit != nil, before.limit == nil, t.active { stopTask(t) }
      if before.label != t.label, ["Needs you", "Done", "Failed", "Goal met", "Goal impossible", "Goal not met", "Limit hit"].contains(t.label) {
        let body =
          t.label == "Needs you"
          ? (pendingInput(t)?.title ?? "It is waiting for your answer.") + " Open Loops to answer it."
          : t.label == "Limit hit"
            ? (t.limit?.resets.map { "It picks up on its own at \(Clock.day($0, now: Date()))." } ?? "Open Loops to resume it.")
            : ((t.goal?.reason ?? t.answer).map { String($0.prefix(160)) } ?? "Open Loops for its answer.")
        notify(
          title: "\(t.title): \(t.label.lowercased())", body: body, category: t.label == "Needs you" ? Notify.answer : nil,
          info: ["task": t.stable])
      }
    }
    if changed { saveTasks() }
    if changed || !needsInput.isEmpty || !inputs.isEmpty { loadInputs() }
    resumeLimited()
    sendQueued()
  }

  func transcript(_ t: BgTask) -> URL? {
    Store.transcript(path: jobs.jobs[t.id]?.transcript, session: t.sessionId, cwd: t.cwd, configs: configs)
  }

  nonisolated static func transcript(path: String?, session: String?, cwd: String?, configs: [String]) -> URL? {
    let fm = FileManager.default
    if let path, fm.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
    guard let session, let cwd else { return nil }
    return configs.lazy
      .map { URL(fileURLWithPath: $0).appending(path: "projects/\(Spend.slug(cwd))/\(session).jsonl") }
      .first { fm.fileExists(atPath: $0.path) }
  }

  func stopTask(_ t: BgTask) {
    Task {
      _ = await Shell.exec(["claude", "stop", t.id], in: paths.repo, config: config)
      await jobs.reconcile()
      refreshTasks()
    }
  }

  func removeTask(_ t: BgTask) {
    Task {
      let (code, out) = await Shell.exec(["claude", "rm", t.id], in: paths.repo, config: config)
      if code != 0 { notice = out.trimmingCharacters(in: .whitespacesAndNewlines) }
      tasks.removeAll { $0.id == t.id }
      numbers[t.id] = nil
      saveTasks()
    }
  }

  func attachTask(_ t: BgTask) {
    let prefix = config == FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude").path
      ? "" : "CLAUDE_CONFIG_DIR='\(config)' "
    terminal(["\(prefix)exec claude attach \(t.id)"])
  }
}

extension Live {
  static func summary(_ url: URL) -> (steps: Int, recent: [String], answer: String?) {
    guard let text = Reader.text(url) else { return (0, [], nil) }
    var steps: [String] = []
    var answer: String?
    for line in text.split(separator: "\n") {
      guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
        obj["type"] as? String == "assistant", let message = obj["message"] as? [String: Any],
        let content = message["content"] as? [[String: Any]]
      else { continue }
      for item in content {
        if item["type"] as? String == "tool_use" {
          let input = item["input"] as? [String: Any] ?? [:]
          steps.append(capitalizedFirst((input["description"] as? String) ?? (item["name"] as? String ?? "Step")))
        } else if item["type"] as? String == "text", let t = item["text"] as? String,
          !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
          answer = t
        }
      }
    }
    return (steps.count, Array(steps.suffix(5)), answer)
  }
}

extension Store {
  func title(of t: BgTask) -> String {
    guard let key = t.key, key.hasPrefix("build:"), let n = Int(key.dropFirst(6)), let issue = issues[n], !t.title.contains(issue.title)
    else { return t.title }
    return "\(t.title) \(issue.title)"
  }

  func pull(of t: BgTask) -> PullRequest? {
    let links = (jobs.jobs[t.id]?.prs ?? []) + (t.prs ?? [])
    let found: [Int]
    if let hit = numbers[t.id], hit.links == links, hit.answer == t.answer {
      found = hit.found
    } else {
      found = (links.reversed().compactMap { Reader.groups(#"/pull/(\d+)"#, in: $0).first }
        + Reader.groups(#"(?:/pull/|PR #)(\d+)"#, in: t.answer ?? "")).compactMap { Int($0) }
      numbers[t.id] = (links, t.answer, found)
    }
    return found.lazy.compactMap { self.pulls[$0] }.first { $0.createdAt.map { $0 > t.started.addingTimeInterval(-60) } ?? false }
  }

}


enum TaskPhase {
  case limit, needsYou, working, merge, met, done, failed, impossible, missed, stopped

  var symbol: String {
    switch self {
    case .limit: "hourglass"
    case .needsYou: "questionmark.bubble"
    case .working: Symbols.askClaude
    case .merge: "arrow.triangle.pull"
    case .met, .done: "checkmark.circle"
    case .failed, .impossible: "xmark.circle"
    case .missed: "minus.circle"
    case .stopped: "stop.circle"
    }
  }
}

extension Store {
  func phase(_ t: BgTask) -> TaskPhase {
    if t.limit != nil { return .limit }
    if t.needsYou { return .needsYou }
    if t.running { return .working }
    if pull(of: t)?.open == true { return .merge }
    if t.goalMet { return .met }
    if let goal = t.goal, t.state == "done" { return goal.verdict == .impossible ? .impossible : .missed }
    switch t.state {
    case "failed": return .failed
    case "done": return .done
    default: return .stopped
    }
  }

  func status(_ t: BgTask, _ phase: TaskPhase) -> String {
    switch phase {
    case .limit: t.limit?.resets.flatMap { $0 > now ? "Limit · \(Clock.time($0))" : nil } ?? "Limit"
    case .needsYou: "Needs you"
    case .working: "Working"
    case .merge: "To merge"
    case .met: "Goal met"
    case .done: "Done"
    case .failed: "Failed"
    case .impossible: "Impossible"
    case .missed: "Not met"
    case .stopped: "Stopped"
    }
  }

  func kind(of t: BgTask) -> String {
    if t.key?.hasPrefix("build:") == true { return "Build" }
    return t.goal == nil ? "Ask" : "Goal"
  }
}
