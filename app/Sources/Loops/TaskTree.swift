import SwiftUI

struct PlanStep: Equatable, Identifiable {
  let id: Int
  let subject: String
  let status: String
  let changed: Date
}

struct SubAgent: Equatable, Identifiable {
  enum State { case running, done, failed, stopped }

  let id: String
  let name: String
  let kind: String
  let parent: String?
  let started: Date?
  let last: Date?
  let state: State
}

enum SubAgents {
  private struct Meta {
    let id: String
    let name: String?
    let kind: String
    var parent: String?
    let toolUseId: String?
    let foreground: Bool
    let file: URL
  }

  private struct Marks {
    var offset: UInt64 = 0
    var finished: [String: String] = [:]
    var results: Set<String> = []
  }

  nonisolated(unsafe) private static var marks: [String: Marks] = [:]
  nonisolated(unsafe) private static var heads: [String: (started: Date?, prompt: String?)] = [:]
  nonisolated(unsafe) private static var ends: [String: (size: Int, ended: Bool)] = [:]
  nonisolated(unsafe) private static var cache: [String: (stamp: String, agents: [SubAgent], used: Date)] = [:]
  private static let lock = NSLock()
  private static let notice = try! Regex(#"<task-id>([0-9a-z]+)</task-id>.*?<status>([a-z_]+)</status>"#)
  private static let result = try! Regex(#""tool_use_id":"(toolu_[A-Za-z0-9]+)""#)

  static func read(_ transcript: URL, live: Bool) -> [SubAgent] {
    lock.lock()
    defer { lock.unlock() }
    sweep(Date())
    let dir = transcript.deletingPathExtension().appending(path: "subagents")
    let runs = names(dir.appending(path: "workflows")).filter { $0.hasPrefix("wf_") }.map { dir.appending(path: "workflows/\($0)") }
    let stamp = ([transcript, dir] + runs + runs.map { $0.appending(path: "journal.jsonl") }).map(stat).joined(separator: "|") + "|\(live)"
    if let hit = cache[transcript.path], hit.stamp == stamp {
      cache[transcript.path]?.used = Date()
      return hit.agents
    }

    var metas = names(dir).filter { $0.hasSuffix(".meta.json") }.compactMap { meta(dir.appending(path: $0)) }
    var journal: [String: String] = [:]
    for run in runs {
      metas += names(run).filter { $0.hasSuffix(".meta.json") }.compactMap { meta(run.appending(path: $0)) }.map { m in
        var m = m
        m.parent = m.parent ?? run.lastPathComponent
        return m
      }
      journal.merge(events(run.appending(path: "journal.jsonl"))) { _, b in b }
    }
    let files = Dictionary(metas.map { ($0.id, $0.file) }, uniquingKeysWith: { a, _ in a })
    var agents = metas.map { m -> SubAgent in
      let head = head(m.file)
      let state: SubAgent.State
      if let j = journal[m.id] {
        state = j == "result" ? .done : j == "failed" ? .failed : live ? .running : .stopped
      } else {
        let seen = scan(m.parent.flatMap { files[$0] } ?? transcript)
        switch seen.finished[m.id] {
        case "completed"?: state = .done
        case let s? where s != "running": state = .failed
        default:
          state = (m.foreground && m.toolUseId.map(seen.results.contains) == true) || ended(m.file) ? .done : live ? .running : .stopped
        }
      }
      let last = (try? FileManager.default.attributesOfItem(atPath: m.file.path))?[.modificationDate] as? Date
      return SubAgent(id: m.id, name: m.name ?? head.prompt ?? m.kind, kind: m.kind, parent: m.parent, started: head.started, last: last, state: state)
    }
    let scripts = names(transcript.deletingPathExtension().appending(path: "workflows/scripts"))
    for run in runs {
      let id = run.lastPathComponent
      let script = scripts.first { $0.hasSuffix("-\(id).js") }.map { String($0.dropLast(id.count + 4)) }
      let kids = agents.filter { $0.parent == id }
      guard !kids.isEmpty else { continue }
      let failed = kids.filter { $0.state == .failed }.count
      let state: SubAgent.State =
        kids.contains { $0.state == .running } ? .running : kids.contains { $0.state == .stopped } ? .stopped : failed > 0 ? .failed : .done
      agents.append(
        SubAgent(
          id: id, name: script ?? "Workflow \(id.dropFirst(3).prefix(8))",
          kind: "workflow · " + (failed > 0 ? "\(kids.count) agents, \(failed) failed" : "\(kids.count) agents"), parent: nil,
          started: kids.compactMap(\.started).min(), last: kids.compactMap(\.last).max(), state: state))
    }
    agents.sort { ($0.started ?? .distantPast) < ($1.started ?? .distantPast) }
    cache[transcript.path] = (stamp, agents, Date())
    return agents
  }

  private static func sweep(_ now: Date) {
    let stale = cache.filter { now.timeIntervalSince($0.value.used) > 600 }.map { String($0.key.dropLast(".jsonl".count)) }
    guard !stale.isEmpty else { return }
    let owned = { (path: String) in stale.contains { path.hasPrefix($0) } }
    cache = cache.filter { !owned($0.key) }
    marks = marks.filter { !owned($0.key) }
    heads = heads.filter { !owned($0.key) }
    ends = ends.filter { !owned($0.key) }
  }

  private static func names(_ dir: URL) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
  }

  private static func stat(_ url: URL) -> String {
    let a = try? FileManager.default.attributesOfItem(atPath: url.path)
    return "\((a?[.size] as? Int) ?? 0):\(((a?[.modificationDate] as? Date) ?? .distantPast).timeIntervalSince1970)"
  }

  private static func meta(_ url: URL) -> Meta? {
    guard let data = FileManager.default.contents(atPath: url.path),
      let m = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return nil }
    let id = url.lastPathComponent.replacingOccurrences(of: "agent-", with: "").replacingOccurrences(of: ".meta.json", with: "")
    return Meta(
      id: id, name: (m["description"] as? String).flatMap { $0.isEmpty ? nil : $0 }, kind: m["agentType"] as? String ?? "agent",
      parent: m["parentAgentId"] as? String, toolUseId: m["toolUseId"] as? String, foreground: m["requestShape"] as? String != "background",
      file: url.deletingLastPathComponent().appending(path: "agent-\(id).jsonl"))
  }

  private static func events(_ url: URL) -> [String: String] {
    guard let text = Reader.text(url) else { return [:] }
    var out: [String: String] = [:]
    for line in text.split(separator: "\n") {
      guard let row = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
        let id = row["agentId"] as? String, let type = row["type"] as? String
      else { continue }
      if out[id] == nil || type != "started" { out[id] = type }
    }
    return out
  }

  private static func head(_ url: URL) -> (started: Date?, prompt: String?) {
    if let hit = heads[url.path] { return hit }
    guard let h = try? FileHandle(forReadingFrom: url) else { return (nil, nil) }
    defer { try? h.close() }
    var data = Data()
    while data.count < 512 * 1024, data.firstIndex(of: 0x0A) == nil, let chunk = try? h.read(upToCount: 64 * 1024), !chunk.isEmpty {
      data.append(chunk)
    }
    guard let end = data.firstIndex(of: 0x0A),
      let row = (try? JSONSerialization.jsonObject(with: data[..<end])) as? [String: Any]
    else { return (nil, nil) }
    let content = (row["message"] as? [String: Any])?["content"]
    let text = (content as? String) ?? ((content as? [[String: Any]])?.first?["text"] as? String)
    let prompt = text?.split(separator: "\n").first.map { String($0.prefix(80)) }
    let found = ((row["timestamp"] as? String).flatMap(Reader.date), prompt)
    heads[url.path] = found
    return found
  }

  private static func ended(_ url: URL) -> Bool {
    let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
    if let hit = ends[url.path], hit.size == size { return hit.ended }
    guard let h = try? FileHandle(forReadingFrom: url) else { return false }
    defer { try? h.close() }
    try? h.seek(toOffset: UInt64(max(0, size - 64 * 1024)))
    let rows = ((try? h.readToEnd()) ?? Data()).split(separator: 0x0A).reversed()
    let last = rows.lazy.compactMap { (try? JSONSerialization.jsonObject(with: Data($0))) as? [String: Any] }
      .first { $0["type"] as? String == "assistant" }
    let done = (last?["message"] as? [String: Any])?["stop_reason"] as? String == "end_turn"
    ends[url.path] = (size, done)
    return done
  }

  private static func scan(_ url: URL) -> Marks {
    var m = marks[url.path] ?? Marks()
    let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int).map(UInt64.init) ?? 0
    if size < m.offset { m = Marks() }
    guard size > m.offset, let h = try? FileHandle(forReadingFrom: url) else { return m }
    defer { try? h.close() }
    try? h.seek(toOffset: m.offset)
    guard let data = try? h.readToEnd(), let end = data.lastIndex(of: 0x0A) else { return m }
    for line in data[..<end].split(separator: 0x0A) {
      let text = String(decoding: line, as: UTF8.self)
      if text.contains("<task-id>") {
        for hit in text.matches(of: notice) {
          if let id = hit.output[1].substring, let status = hit.output[2].substring { m.finished[String(id)] = String(status) }
        }
      }
      if text.contains("\"tool_result\"") {
        for hit in text.matches(of: result) { if let id = hit.output[1].substring { m.results.insert(String(id)) } }
      }
    }
    m.offset += UInt64(data.distance(from: data.startIndex, to: end) + 1)
    marks[url.path] = m
    return m
  }
}

extension Store {
  func loadSubAgents(_ t: BgTask) async -> [SubAgent] {
    let path = jobs.jobs[t.id]?.transcript
    let configs = configs
    let live = t.active
    return await Task.detached(priority: .userInitiated) {
      Store.transcript(path: path, session: t.sessionId, cwd: t.cwd, configs: configs).map { SubAgents.read($0, live: live) } ?? []
    }.value
  }

  func finishes(_ t: BgTask, plan: [PlanStep], now: Date) -> Date? {
    let done = plan.filter { $0.status == "completed" }.count
    let left = plan.count - done
    guard done > 0, left > 0 else { return nil }
    let pace = now.timeIntervalSince(t.started) / Double(done)
    guard pace > 0 else { return nil }
    return now.addingTimeInterval(pace * Double(left))
  }
}

struct TimeLeft: View {
  let finish: Date
  let now: Date

  var body: some View {
    if finish > now.addingTimeInterval(60) {
      Text("about \(Text(.currentDate, format: .offset(to: finish, allowedFields: [.hour, .minute], maxFieldCount: 2, sign: .never))) left")
        .help("An estimate from the pace of the steps finished so far")
    } else {
      Text("any minute now")
        .help("Past the estimate from the pace of the steps finished so far")
    }
  }
}

struct PlanSection: View {
  let task: BgTask
  let plan: [PlanStep]

  private static let shown = 10

  private var window: ArraySlice<PlanStep> {
    guard plan.count > Self.shown else { return plan[...] }
    let next = plan.firstIndex { $0.status != "completed" } ?? plan.count
    let start = max(0, min(next - 2, plan.count - Self.shown))
    return plan[start..<start + Self.shown]
  }

  var body: some View {
    let done = plan.filter { $0.status == "completed" }.count
    Section {
      ForEach(window) { step in
        Label {
          Text(step.subject).foregroundStyle(step.status == "completed" ? .secondary : .primary)
        } icon: {
          mark(step.status)
        }
        .help(step.subject)
      }
      if plan.count > window.count {
        Text("\(plan.count - window.count) more steps").foregroundStyle(.secondary)
      }
    } header: {
      HStack {
        Text("Plan")
        Spacer()
        Text("\(done) of \(plan.count)").monospacedDigit()
      }
    }
  }

  @ViewBuilder private func mark(_ status: String) -> some View {
    switch status {
    case "completed": Image(icon: "checkmark.circle", size: 14).foregroundStyle(.green)
    case "in_progress":
      if task.active { WorkingIcon(symbol: "circle.dashed") } else { Image(icon: "circle.dashed", size: 14).foregroundStyle(.secondary) }
    default: Image(icon: "circle", size: 14).foregroundStyle(.tertiary)
    }
  }
}

struct AgentsSection: View {
  @Environment(Store.self) private var store
  let agents: [SubAgent]
  @State private var open: Set<String> = []

  private static let roots = 8

  var body: some View {
    let ids = Set(agents.map(\.id))
    let children = Dictionary(grouping: agents.filter { $0.parent.map(ids.contains) == true }) { $0.parent ?? "" }
    let roots = agents.filter { $0.parent.map(ids.contains) != true }
    let working = agents.filter { !$0.id.hasPrefix("wf_") }
    let running = working.filter { $0.state == .running }.count
    Section {
      ForEach(roots.suffix(Self.roots)) { agent in
        let kids = children[agent.id] ?? []
        if kids.isEmpty {
          AgentLine(agent: agent, now: store.now)
        } else {
          DisclosureGroup(isExpanded: expanded(agent)) {
            ForEach(kids) { AgentLine(agent: $0, now: store.now) }
          } label: {
            AgentLine(agent: agent, now: store.now)
          }
        }
      }
      if roots.count > Self.roots {
        Text("\(roots.count - Self.roots) earlier").foregroundStyle(.secondary)
      }
    } header: {
      HStack {
        Text("Agents")
        Spacer()
        Text(running > 0 ? "\(running) of \(working.count) running" : plural(working.count, "agent")).monospacedDigit()
      }
    }
  }

  private func expanded(_ agent: SubAgent) -> Binding<Bool> {
    Binding(
      get: { open.contains(agent.id) != (agent.state == .running) },
      set: { on in
        if on != (agent.state == .running) { open.insert(agent.id) } else { open.remove(agent.id) }
      })
  }
}

struct AgentLine: View {
  let agent: SubAgent
  let now: Date

  var body: some View {
    LabeledContent {
      time.monospacedDigit()
    } label: {
      Label {
        Text(agent.name).lineLimit(1)
        Text(agent.kind).lineLimit(1)
      } icon: {
        icon
      }
    }
    .help(agent.name)
  }

  @ViewBuilder private var icon: some View {
    switch agent.state {
    case .running: WorkingIcon(symbol: Symbols.askClaude)
    case .done: Image(icon: "checkmark.circle", size: 14).foregroundStyle(.green)
    case .failed: Image(icon: "xmark.circle", size: 14).foregroundStyle(.red)
    case .stopped: Image(icon: "stop.circle", size: 14).foregroundStyle(.secondary)
    }
  }

  @ViewBuilder private var time: some View {
    if let started = agent.started {
      if agent.state == .running {
        Text(.currentDate, format: .offset(to: started, allowedFields: [.hour, .minute], maxFieldCount: 2, sign: .never))
      } else if let last = agent.last {
        let took = last.timeIntervalSince(started)
        Text(took < 60 ? "<1m" : Clock.span(took))
      }
    }
  }
}
