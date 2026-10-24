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
  nonisolated(unsafe) private static var seen: [String: (size: UInt64, value: (Int, [LiveStep], String?, Date?, Date?))] = [:]
  nonisolated(unsafe) private static var journals: [String: (size: UInt64, value: ([String], [String: String], [String: String], Set<String>))] = [:]
  private static let lock = NSLock()

  private static func size(_ url: URL) -> UInt64 {
    ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value ?? 0
  }

  static func read(config: String, runner: URL, running: Set<String>, now: Date) -> LiveTick? {
    let fm = FileManager.default
    let slug = runner.path.replacingOccurrences(of: "[^A-Za-z0-9-]", with: "-", options: .regularExpression)
    let projects = URL(fileURLWithPath: config).appending(path: "projects/\(slug)")
    var best: (url: URL, modified: Date)?
    for session in (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? [] {
      let flows = session.appending(path: "subagents/workflows")
      for flow in (try? fm.contentsOfDirectory(at: flows, includingPropertiesForKeys: nil)) ?? []
      where flow.lastPathComponent.hasPrefix("wf_") {
        let m = modified(flow.appending(path: "journal.jsonl")) ?? .distantPast
        if m > (best?.modified ?? .distantPast) { best = (flow, m) }
      }
    }
    let manual = byHand(projects, running: running, now: now)
    guard let best, now.timeIntervalSince(best.modified) < 3 * 3600 else {
      return manual.isEmpty ? nil : LiveTick(id: "by-hand", started: manual.compactMap(\.started).min(), agents: manual)
    }

    let (order, labels, briefs, done) = journal(best.url.appending(path: "journal.jsonl"))

    let agents = order.map { id -> LiveAgent in
      let label = labels[id] ?? ""
      let parts = label.split(separator: ":").map(String.init)
      let role: String? =
        parts.count > 1 ? (parts[1] == "judgment" ? "judging its review panel" : "\(parts[1]) reviewer") : nil
      let file = best.url.appending(path: "agent-\(id).jsonl")
      let (steps, recent, thought, first, last) = transcript(file)
      let lastAt = last ?? modified(file)
      let finished = done.contains(id)
      return LiveAgent(
        id: id, loop: parts.first ?? label, role: role, started: first, finished: finished,
        stalled: !finished && now.timeIntervalSince(lastAt ?? now) > 20 * 60, steps: steps, recent: recent,
        thought: thought, lastAt: lastAt, brief: briefs[id], tokens: Spend.agent(file).tokens)
    }
    let all = agents + manual
    return LiveTick(id: best.url.lastPathComponent, started: all.compactMap(\.started).min(), agents: all)
  }

  private static func byHand(_ projects: URL, running: Set<String>, now: Date) -> [LiveAgent] {
    let fm = FileManager.default
    var out: [LiveAgent] = []
    for file in (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
    where file.pathExtension == "jsonl" {
      guard let m = modified(file), now.timeIntervalSince(m) < 3 * 3600,
        let handle = try? FileHandle(forReadingFrom: file)
      else { continue }
      let head = (try? handle.read(upToCount: 64 * 1024)).map { String(decoding: $0, as: UTF8.self) } ?? ""
      try? handle.close()
      guard let loop = Reader.groups(#"<command-name>/(loop-[a-z-]+)</command-name>"#, in: head).first else { continue }
      let (steps, recent, thought, first, last) = transcript(file)
      let lastAt = last ?? m
      let finished = !running.contains(loop) && now.timeIntervalSince(lastAt) > 90
      out.append(
        LiveAgent(
          id: file.lastPathComponent, loop: loop, role: "started by you", started: first, finished: finished,
          stalled: !finished && now.timeIntervalSince(lastAt) > 20 * 60, steps: steps, recent: recent, thought: thought,
          lastAt: lastAt, brief: nil, tokens: Spend.agent(file).tokens))
    }
    return out
  }

  private static func modified(_ url: URL) -> Date? {
    (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
  }

  private static func journal(_ url: URL) -> ([String], [String: String], [String: String], Set<String>) {
    let bytes = size(url)
    lock.lock()
    let hit = journals[url.path]
    lock.unlock()
    if let hit, hit.size == bytes { return hit.value }
    var order: [String] = []
    var labels: [String: String] = [:]
    var briefs: [String: String] = [:]
    var done = Set<String>()
    for line in (Reader.text(url) ?? "").split(separator: "\n") {
      guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
        let type = obj["type"] as? String, let id = obj["agentId"] as? String
      else { continue }
      if type == "started" {
        if labels[id] == nil { order.append(id) }
        labels[id] = obj["label"] as? String ?? ""
      } else if type == "result" {
        done.insert(id)
        if let r = obj["result"] as? [String: Any], let b = r["brief"] as? String { briefs[id] = b }
      }
    }
    lock.lock()
    journals[url.path] = (bytes, (order, labels, briefs, done))
    lock.unlock()
    return (order, labels, briefs, done)
  }

  private static func transcript(_ url: URL) -> (Int, [LiveStep], String?, Date?, Date?) {
    let bytes = size(url)
    lock.lock()
    let hit = seen[url.path]
    lock.unlock()
    if let hit, hit.size == bytes { return hit.value }
    let value = parse(url)
    lock.lock()
    seen[url.path] = (bytes, value)
    lock.unlock()
    return value
  }

  private static func parse(_ url: URL) -> (Int, [LiveStep], String?, Date?, Date?) {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return (0, [], nil, nil, nil) }
    defer { try? handle.close() }
    let head = (try? handle.read(upToCount: 4096)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    let first = head.split(separator: "\n").first.flatMap(timestamp)
    let size = (try? handle.seekToEnd()) ?? 0
    try? handle.seek(toOffset: size > UInt64(lineBudget) ? size - UInt64(lineBudget) : 0)
    let data = (try? handle.readToEnd()) ?? Data()
    let text = String(decoding: data, as: UTF8.self)
    var lines = text.split(separator: "\n")
    if size > UInt64(lineBudget), !lines.isEmpty { lines.removeFirst() }

    var steps: [LiveStep] = []
    var thought: String?
    var last: Date?
    for line in lines {
      guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
      let at = (obj["timestamp"] as? String).flatMap(Reader.date)
      if let at { last = at }
      guard obj["type"] as? String == "assistant", let message = obj["message"] as? [String: Any],
        let content = message["content"] as? [[String: Any]]
      else { continue }
      for item in content {
        if item["type"] as? String == "tool_use" {
          steps.append(LiveStep(id: steps.count, at: at, text: describe(item)))
        } else if item["type"] as? String == "text", let t = item["text"] as? String,
          !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
          thought = t
        }
      }
    }
    let total = size > UInt64(lineBudget) ? max(steps.count, approximateSteps(url)) : steps.count
    return (total, Array(steps.suffix(12)), thought.map { String($0.prefix(400)) }, first, last)
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
