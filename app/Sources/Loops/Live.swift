import Foundation

struct LiveStep: Identifiable {
  let id: Int
  let at: Date?
  let text: String
}

struct LiveAgent: Identifiable {
  let id: String
  let loop: String
  let role: String?
  let started: Date?
  let finished: Bool
  let stalled: Bool
  let steps: Int
  let recent: [LiveStep]
  let thought: String?
  let lastAt: Date?
  let brief: String?
  var tokens = Tokens()

  var current: String? { recent.last?.text }

  func advanced(_ text: String, at: Date) -> LiveAgent {
    LiveAgent(
      id: id, loop: loop, role: role, started: started ?? at, finished: false, stalled: false, steps: steps + 1,
      recent: Array((recent + [LiveStep(id: steps, at: at, text: text)]).suffix(12)), thought: thought, lastAt: at, brief: brief,
      tokens: tokens)
  }
}

struct LiveTick {
  let id: String
  let started: Date?
  let agents: [LiveAgent]

  var running: Bool { agents.contains { !$0.finished && !$0.stalled } }

  func agents(for loop: String) -> [LiveAgent] { agents.filter { $0.loop == loop } }
}

enum Live {
  private static let lineBudget = 384 * 1024

  private final class Tail {
    var offset = 0
    var steps = 0
    var recent: [LiveStep] = []
    var thought: String?
    var first: Date?
    var last: Date?
  }

  private final class Journal {
    var offset = 0
    var order: [String] = []
    var labels: [String: String] = [:]
    var briefs: [String: String] = [:]
    var done = Set<String>()
  }

  private struct Scan {
    var dirs: [String: Date] = [:]
    var flows: [String: Date] = [:]
  }

  nonisolated(unsafe) private static var tails: [String: Tail] = [:]
  nonisolated(unsafe) private static var journals: [String: Journal] = [:]
  nonisolated(unsafe) private static var scans: [String: Scan] = [:]
  private static let lock = NSLock()

  static func read(config: String, runner: URL, running: Set<String>, now: Date) -> LiveTick? {
    lock.lock()
    defer { lock.unlock() }
    let projects = URL(fileURLWithPath: config).appending(path: "projects/\(Spend.slug(runner.path))")
    var touched = Set<String>()
    defer { sweep(projects.path + "/", keeping: touched) }
    let sessions = Spend.listing(projects).filter {
      !$0.directory && $0.url.pathExtension == "jsonl" && now.timeIntervalSince($0.modified) < 3 * 3600
    }
    let manual = byHand(sessions, running: running, now: now, touched: &touched)
    guard let best = newest(projects, sessions: sessions, now: now), now.timeIntervalSince(best.modified) < 3 * 3600 else {
      return manual.isEmpty ? nil : LiveTick(id: "by-hand", started: manual.compactMap(\.started).min(), agents: manual)
    }

    let file = best.url.appending(path: "journal.jsonl")
    touched.insert(file.path)
    let j = journal(file)

    let agents = j.order.map { id -> LiveAgent in
      let label = j.labels[id] ?? ""
      let parts = label.split(separator: ":").map(String.init)
      let role: String? =
        parts.count > 1 ? (parts[1] == "judgment" ? "judging its review panel" : "\(parts[1]) reviewer") : nil
      let file = best.url.appending(path: "agent-\(id).jsonl")
      let info = Spend.stat(file)
      touched.insert(file.path)
      let t = transcript(file, size: info.size)
      let lastAt = t.last ?? (info.modified == .distantPast ? nil : info.modified)
      let finished = j.done.contains(id)
      return LiveAgent(
        id: id, loop: parts.first ?? label, role: role, started: t.first, finished: finished,
        stalled: !finished && now.timeIntervalSince(lastAt ?? now) > 20 * 60, steps: t.steps, recent: t.recent,
        thought: t.thought.map { String($0.prefix(400)) }, lastAt: lastAt, brief: j.briefs[id], tokens: Spend.agent(file, stat: info).tokens)
    }
    let all = agents + manual
    return LiveTick(id: best.url.lastPathComponent, started: all.compactMap(\.started).min(), agents: all)
  }

  private static func byHand(_ sessions: [Spend.File], running: Set<String>, now: Date, touched: inout Set<String>) -> [LiveAgent] {
    var out: [LiveAgent] = []
    for file in sessions {
      guard let loop = Spend.loop(file.url, size: file.size) else { continue }
      touched.insert(file.url.path)
      let t = transcript(file.url, size: file.size)
      let lastAt = t.last ?? file.modified
      let finished = !running.contains(loop) && now.timeIntervalSince(lastAt) > 90
      out.append(
        LiveAgent(
          id: file.name, loop: loop, role: "started by you", started: t.first, finished: finished,
          stalled: !finished && now.timeIntervalSince(lastAt) > 20 * 60, steps: t.steps, recent: t.recent,
          thought: t.thought.map { String($0.prefix(400)) }, lastAt: lastAt, brief: nil, tokens: Spend.agent(file.url, stat: file.stat).tokens))
    }
    return out
  }

  private static func newest(_ projects: URL, sessions: [Spend.File], now: Date) -> (url: URL, modified: Date)? {
    var scan = scans[projects.path] ?? Scan()
    let live = sessions.map { $0.url.deletingPathExtension().path + "/" }
    for session in sessions {
      let flows = session.url.deletingPathExtension().appending(path: "subagents/workflows")
      let m = Spend.stat(flows).modified
      guard m != .distantPast, scan.dirs[flows.path] != m else { continue }
      scan.dirs[flows.path] = m
      for name in (try? FileManager.default.contentsOfDirectory(atPath: flows.path)) ?? [] where name.hasPrefix("wf_") {
        let path = flows.appending(path: name).path
        if scan.flows[path] == nil { scan.flows[path] = .distantPast }
      }
    }
    var best: (url: URL, modified: Date)?
    for (path, seen) in scan.flows {
      var m = seen
      if now.timeIntervalSince(seen) < 3 * 3600 || seen == .distantPast {
        m = Spend.stat(URL(fileURLWithPath: path).appending(path: "journal.jsonl")).modified
        scan.flows[path] = m
      }
      if m > (best?.modified ?? .distantPast) { best = (URL(fileURLWithPath: path), m) }
    }
    scan.flows = scan.flows.filter { path, m in now.timeIntervalSince(m) < 3 * 3600 || live.contains { path.hasPrefix($0) } }
    scan.dirs = scan.dirs.filter { path, _ in live.contains { path.hasPrefix($0) } }
    scans[projects.path] = scan
    return best
  }

  private static func sweep(_ root: String, keeping touched: Set<String>) {
    tails = tails.filter { !$0.key.hasPrefix(root) || touched.contains($0.key) }
    journals = journals.filter { !$0.key.hasPrefix(root) || touched.contains($0.key) }
  }

  private static func journal(_ url: URL) -> Journal {
    let size = Spend.stat(url).size
    let j = journals[url.path].flatMap { $0.offset <= size ? $0 : nil } ?? Journal()
    journals[url.path] = j
    guard size > j.offset, let h = try? FileHandle(forReadingFrom: url) else { return j }
    defer { try? h.close() }
    try? h.seek(toOffset: UInt64(j.offset))
    j.offset += Spend.chunks(h) { data in
      for line in data.split(separator: 0x0A) {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
          let type = obj["type"] as? String, let id = obj["agentId"] as? String
        else { continue }
        if type == "started" {
          if j.labels[id] == nil { j.order.append(id) }
          j.labels[id] = obj["label"] as? String ?? ""
        } else if type == "result" {
          j.done.insert(id)
          if let r = obj["result"] as? [String: Any], let b = r["brief"] as? String { j.briefs[id] = b }
        }
      }
    }
    return j
  }

  private static func transcript(_ url: URL, size: Int) -> Tail {
    let t = tails[url.path].flatMap { $0.offset <= size ? $0 : nil } ?? Tail()
    tails[url.path] = t
    guard size > t.offset, let h = try? FileHandle(forReadingFrom: url) else { return t }
    defer { try? h.close() }
    var start = t.offset
    var whole = false
    if t.offset == 0 {
      let head = (try? h.read(upToCount: 4096)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
      t.first = head.split(separator: "\n").first.flatMap(timestamp)
      if size > lineBudget {
        start = size - lineBudget
        whole = true
      }
    }
    try? h.seek(toOffset: UInt64(start))
    var found: [(at: Date?, text: String)] = []
    var skip = whole
    let used = Spend.chunks(h) { data in
      for line in data.split(separator: 0x0A) {
        if skip {
          skip = false
          continue
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
        let at = (obj["timestamp"] as? String).flatMap(Reader.date)
        if let at { t.last = at }
        guard obj["type"] as? String == "assistant", let message = obj["message"] as? [String: Any],
          let content = message["content"] as? [[String: Any]]
        else { continue }
        for item in content {
          if item["type"] as? String == "tool_use" {
            found.append((at, describe(item)))
          } else if item["type"] as? String == "text", let text = item["text"] as? String,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          {
            t.thought = text
          }
        }
      }
    }
    t.offset = start + used
    let base = whole ? max(found.count, approximateSteps(url)) - found.count : t.steps
    let steps = found.enumerated().map { LiveStep(id: base + $0.offset, at: $0.element.at, text: $0.element.text) }
    t.steps = base + found.count
    t.recent = Array((t.recent + steps).suffix(12))
    return t
  }

  private static func timestamp(_ line: Substring) -> Date? {
    guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { return nil }
    return (obj["timestamp"] as? String).flatMap(Reader.date)
  }

  private static func approximateSteps(_ url: URL) -> Int {
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return 0 }
    let needle = Data("\"type\":\"tool_use\"".utf8)
    var count = 0
    var range = data.startIndex..<data.endIndex
    while let r = data.range(of: needle, in: range) {
      count += 1
      range = r.upperBound..<data.endIndex
    }
    return count
  }

  static func describe(_ item: [String: Any]) -> String {
    let name = item["name"] as? String ?? "Tool"
    let input = item["input"] as? [String: Any] ?? [:]
    if let d = input["description"] as? String, !d.isEmpty { return capitalizedFirst(d) }
    if let p = input["file_path"] as? String {
      let file = (p as NSString).lastPathComponent
      switch name {
      case "Read": return "Reads \(file)"
      case "Edit", "MultiEdit": return "Edits \(file)"
      case "Write": return "Writes \(file)"
      default: return "\(name) \(file)"
      }
    }
    if let pattern = input["pattern"] as? String { return "Searches for \(pattern.prefix(60))" }
    if let skill = input["skill"] as? String { return "Loads the \(skill) skill" }
    if let command = input["command"] as? String { return String(command.prefix(90)) }
    if let prompt = input["prompt"] as? String { return "\(name): \(prompt.prefix(80))" }
    if let url = input["url"] as? String { return "Fetches \(url.prefix(80))" }
    if let query = input["query"] as? String, name != "ToolSearch" { return "Searches for \(query.prefix(70))" }
    switch name {
    case "ToolSearch": return "Loads the tools it needs"
    case "StructuredOutput": return "Writes its brief"
    case "TodoWrite", "TaskCreate", "TaskUpdate": return "Updates its task list"
    case "Agent", "Task": return "Starts a helper agent"
    case "Workflow": return "Runs a workflow"
    case "Monitor": return "Watches a background job"
    case "SendMessage": return "Messages another agent"
    case "BashOutput", "TaskOutput": return "Checks a background job"
    default: return name.replacingOccurrences(of: "mcp__", with: "").replacingOccurrences(of: "_", with: " ")
    }
  }
}
