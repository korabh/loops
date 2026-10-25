import Foundation

struct Tokens: Codable, Equatable {
  var input = 0
  var output = 0
  var cacheWrite = 0
  var cacheRead = 0
  var cost = 0.0
  var readCost = 0.0

  var total: Int { input + output + cacheWrite }
  var isEmpty: Bool { total == 0 && cacheRead == 0 }

  var detail: String {
    "\(input.compact) in · \(output.compact) out · \(cacheWrite.compact) cache writes · \(cacheRead.compact) cache reads · \(cost.usd) at API prices"
  }

  func scaled(_ f: Double) -> Tokens {
    var t = self
    t.cost *= f
    t.readCost *= f
    return t
  }

  var label: String { "\(total.compact) tokens · \(cost.usd)" }

  static func + (a: Tokens, b: Tokens) -> Tokens {
    Tokens(
      input: a.input + b.input, output: a.output + b.output, cacheWrite: a.cacheWrite + b.cacheWrite,
      cacheRead: a.cacheRead + b.cacheRead, cost: a.cost + b.cost, readCost: a.readCost + b.readCost)
  }

  static func += (a: inout Tokens, b: Tokens) { a = a + b }
}

struct Usage: Codable, Equatable {
  var tokens = 0
  var cost = 0.0

  var label: String { "\(tokens.compact) tokens · \(cost.usd)" }

  init(tokens: Int = 0, cost: Double = 0) {
    self.tokens = tokens
    self.cost = cost
  }

  init(result: [String: Any]) {
    let models = (result["modelUsage"] as? [String: [String: Any]] ?? [:]).values
    tokens = models.reduce(0) { sum, m in
      sum + ["inputTokens", "outputTokens", "cacheCreationInputTokens"].reduce(0) { $0 + (m[$1] as? Int ?? 0) }
    }
    cost = result["total_cost_usd"] as? Double ?? 0
  }

  static func + (a: Usage, b: Usage) -> Usage { Usage(tokens: a.tokens + b.tokens, cost: a.cost + b.cost) }
}

extension Int {
  var compact: String { formatted(.number.notation(.compactName).locale(Locale(identifier: "en_US"))) }
}

extension Double {
  var usd: String {
    let style = FloatingPointFormatStyle<Double>.Currency(code: "USD", locale: Locale(identifier: "en_US"))
      .precision(.fractionLength(self >= 100 ? 0 : 2))
    return self > 0 && self < 0.01 ? "<" + 0.01.formatted(style) : formatted(style)
  }
}

enum Price {
  struct Rate {
    let input: Double
    let output: Double
    let read: Double
  }

  static func rate(_ model: String) -> Rate {
    let m = model.lowercased()
    if m.contains("fable") || m.contains("mythos") { return Rate(input: 10, output: 50, read: 0.25) }
    if m.contains("opus-5-5") || m == "opus" { return Rate(input: 4, output: 20, read: 0.2) }
    if m.contains("opus") { return Rate(input: 5, output: 25, read: 0.5) }
    if m.contains("sonnet-5") || m == "sonnet" { return Rate(input: 2, output: 10, read: 0.2) }
    if m.contains("sonnet") { return Rate(input: 3, output: 15, read: 0.3) }
    if m.contains("haiku-5") || m == "haiku" { return Rate(input: 0.1, output: 0.5, read: 0.01) }
    if m.contains("haiku") { return Rate(input: 1, output: 5, read: 0.1) }
    return Rate(input: 0, output: 0, read: 0)
  }

  static func tokens(_ u: [String: Any], model: String) -> Tokens {
    let r = rate(model)
    let input = u["input_tokens"] as? Int ?? 0
    let output = u["output_tokens"] as? Int ?? 0
    let write = u["cache_creation_input_tokens"] as? Int ?? 0
    let read = u["cache_read_input_tokens"] as? Int ?? 0
    let hour = min(write, (u["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"] as? Int ?? 0)
    let readCost = Double(read) * r.read / 1e6
    let cost =
      (Double(input) * r.input + Double(write - hour) * r.input * 1.25 + Double(hour) * r.input * 2 + Double(output) * r.output) / 1e6
      + readCost
    return Tokens(input: input, output: output, cacheWrite: write, cacheRead: read, cost: cost, readCost: readCost)
  }

  static func reprice(_ t: Tokens, as model: String) -> Double {
    let r = rate(model)
    return (Double(t.input) * r.input + Double(t.cacheWrite) * r.input * 1.25 + Double(t.output) * r.output + Double(t.cacheRead) * r.read) / 1e6
  }
}

struct Output: Codable, Equatable {
  let what: String
  let tokens: Int
  let later: Int
  let reread: Double
  let file: Bool
}

struct AgentStat: Codable, Equatable {
  var tokens = Tokens()
  var days: [String: Tokens] = [:]
  var turns = 0
  var first: Date?
  var last: Date?
  var model = ""
  var acted = false
  var startup = 0
  var fixed = 0.0
  var fixedTokens = 0
  var outputs: [Output] = []
  var billed: Double?
  var process: Int?
  var limited = false
}

struct RunStat: Identifiable, Codable, Equatable {
  let id: String
  let loop: String
  var at: Date
  var end: Date
  var main = Tokens()
  var panel = Tokens()
  var judgment = Tokens()
  var helpers = Tokens()
  var reviewers = 0
  var turns = 0
  var acted = false
  var failed = false
  var limited = false
  var finished = true
  var byHand = false
  var model = ""
  var startup = 0
  var agents = 0
  var fixed = 0.0
  var fixedTokens = 0
  var outputs: [Output] = []
  var brief: String?

  var tokens: Tokens { main + helpers + panel + judgment }

  mutating func scale(_ f: Double) {
    main = main.scaled(f)
    helpers = helpers.scaled(f)
    panel = panel.scaled(f)
    judgment = judgment.scaled(f)
    fixed *= f
  }
  var minutes: Double { max(0, end.timeIntervalSince(at) / 60) }
  var quiet: Bool { finished && !failed && !limited && !acted }

  var outcome: String {
    if !finished { return "still running" }
    if limited { return "stopped by the usage limit" }
    if failed { return "ended without a result" }
    return acted ? "did work" : "changed nothing"
  }
}

struct SpendReport: Codable, Equatable {
  var loaded = false
  var today = Tokens()
  var yesterday = Tokens()
  var todayLoops: [String: Tokens] = [:]
  var runner = Tokens()
  var tasks = Tokens()
  var runs: [RunStat] = []
  var factor = 1.0
  var samples = 0

  func runs(_ loop: String) -> [RunStat] { runs.filter { $0.loop == loop } }
  var week: Tokens { runs.map(\.tokens).reduce(Tokens(), +) }
}

private final class Transcript {
  let lock = NSLock()
  var used = Date()
  var offset = 0
  var quiet = false
  var headed = false
  var loop: String?
  var usage: [String: (Tokens, String)] = [:]
  var order: [String] = []
  var tools: [String: String] = [:]
  var results: [(what: String, chars: Int, turn: Int, file: Bool)] = []
  var first: Date?
  var last: Date?
  var model = ""
  var acted = false
  var limited = false
  var billed: Double?
  var process: Int?
  var stat = AgentStat()

  private static let needles = ["\"type\":\"assistant\"", "\"tool_result\"", "\"cost-state\""].map { Data($0.utf8) }

  func reset() {
    offset = 0
    quiet = false
    usage = [:]
    order = []
    tools = [:]
    results = []
    first = nil
    last = nil
    model = ""
    acted = false
    limited = false
    billed = nil
    process = nil
    stat = AgentStat()
  }

  func collapse() {
    usage = [:]
    order = []
    tools = [:]
    results = []
    quiet = true
  }

  func consume(_ url: URL) {
    guard let h = try? FileHandle(forReadingFrom: url) else { return }
    defer { try? h.close() }
    try? h.seek(toOffset: UInt64(offset))
    let used = Spend.chunks(h) { feed($0) }
    guard used > 0 else { return }
    offset += used
    stat = summarize()
  }

  func feed(_ data: Data) {
    for line in data.split(separator: UInt8(ascii: "\n")) where Self.needles.contains(where: { line.range(of: $0) != nil }) {
      guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
      if obj["type"] as? String == "cost-state" {
        billed = obj["totalCostUSD"] as? Double
        process = (obj["startTime"] as? NSNumber)?.intValue
        continue
      }
      guard let message = obj["message"] as? [String: Any] else { continue }
      let at = (obj["timestamp"] as? String).flatMap(Reader.date)
      if let at {
        if first == nil { first = at }
        last = at
      }
      switch obj["type"] as? String {
      case "assistant":
        limited = obj["isApiErrorMessage"] as? Bool == true && obj["error"] as? String == "rate_limit"
        let m = message["model"] as? String ?? ""
        if !m.isEmpty, !m.hasPrefix("<") { model = m }
        let id = (message["id"] as? String) ?? (obj["uuid"] as? String) ?? UUID().uuidString
        if usage[id] == nil { order.append(id) }
        if let u = message["usage"] as? [String: Any] { usage[id] = (Price.tokens(u, model: m), at.map(Spend.day) ?? "") }
        for item in (message["content"] as? [[String: Any]]) ?? [] where item["type"] as? String == "tool_use" {
          let name = item["name"] as? String ?? ""
          let input = item["input"] as? [String: Any] ?? [:]
          if let id = item["id"] as? String {
            let l = Spend.label(name, input)
            let reads = name == "Read" || ["cat ", "sed ", "head ", "tail ", "nl "].contains { l.hasPrefix($0) }
            tools[id] = (reads ? "Read:" : "") + l
          }
          if !acted, Spend.acts(name, input) { acted = true }
        }
      case "user":
        for item in (message["content"] as? [[String: Any]]) ?? [] where item["type"] as? String == "tool_result" {
          let use = item["tool_use_id"] as? String ?? ""
          let chars = Self.length(item["content"])
          if chars >= Spend.big {
            let what = tools[use] ?? "a tool"
            results.append((what.replacingOccurrences(of: "Read:", with: ""), chars, order.count, what.hasPrefix("Read:")))
          }
          tools[use] = nil
        }
      default:
        continue
      }
    }
  }

  func summarize() -> AgentStat {
    var s = AgentStat()
    s.first = first
    s.last = last
    s.model = model
    s.acted = acted
    s.limited = limited
    s.billed = billed
    s.process = process
    s.turns = order.count
    for id in order {
      guard let u = usage[id] else { continue }
      s.tokens += u.0
      s.days[u.1, default: Tokens()] += u.0
    }
    if let id = order.first, let t = usage[id]?.0 { s.startup = t.input + t.cacheWrite + t.cacheRead }
    let rate = Price.rate(model)
    s.fixed = Double(s.startup) * (rate.input * 1.25 + Double(max(0, s.turns - 1)) * rate.read) / 1e6
    s.fixedTokens = s.startup * max(1, s.turns)
    s.outputs = results.map { r in
      let tokens = r.chars / 4
      let later = max(0, s.turns - r.turn)
      return Output(what: r.what, tokens: tokens, later: later, reread: Double(tokens * later) * rate.read / 1e6, file: r.file)
    }
    return s
  }

  private static func length(_ content: Any?) -> Int {
    if let s = content as? String { return s.utf8.count }
    guard let blocks = content as? [[String: Any]] else { return 0 }
    return blocks.reduce(0) { $0 + (($1["text"] as? String)?.utf8.count ?? 0) }
  }
}

enum Spend {
  struct File {
    let url: URL
    let size: Int
    let modified: Date
    let directory: Bool

    var name: String { url.lastPathComponent }
    var stat: (size: Int, modified: Date) { (size, modified) }
  }

  private struct Journal {
    var order: [(id: String, label: String)] = []
    var done = Set<String>()
    var briefs: [String: String] = [:]
    var failed = Set<String>()
  }

  private struct Sample {
    var process: Int?
    var billed: Double?
    var mine = 0.0
  }

  nonisolated(unsafe) private static var cache: [String: Transcript] = [:]
  nonisolated(unsafe) private static var journals: [String: (size: Int, modified: Date, journal: Journal, used: Date)] = [:]
  nonisolated(unsafe) private static var metas: [String: (modified: Date, parent: String?, loop: String?, used: Date)] = [:]
  nonisolated(unsafe) private static var samples: [String: (size: Int, modified: Date, sample: Sample, used: Date)] = [:]
  private static let lock = NSLock()
  static let big = 4_000
  private static let dayFormat: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    return f
  }()

  static func day(_ d: Date) -> String { dayFormat.string(from: d) }

  static func slug(_ path: String) -> String {
    path.replacingOccurrences(of: "[^A-Za-z0-9-]", with: "-", options: .regularExpression)
  }

  static func chunks(_ h: FileHandle, _ feed: (Data) -> Void) -> Int {
    var used = 0
    var carry = Data()
    while let chunk = try? h.read(upToCount: 4 << 20), !chunk.isEmpty {
      carry.append(chunk)
      guard let end = carry.lastIndex(of: 0x0A) else { continue }
      feed(carry[carry.startIndex...end])
      used += carry.distance(from: carry.startIndex, to: end) + 1
      carry = Data(carry[carry.index(after: end)...])
    }
    return used
  }

  static func listing(_ dir: URL) -> [File] {
    let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey]
    let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: Array(keys))) ?? []
    return urls.map { url in
      let v = try? url.resourceValues(forKeys: keys)
      return File(url: url, size: v?.fileSize ?? 0, modified: v?.contentModificationDate ?? .distantPast, directory: v?.isDirectory ?? false)
    }
  }

  static func stat(_ url: URL) -> (size: Int, modified: Date) {
    let a = try? FileManager.default.attributesOfItem(atPath: url.path)
    return ((a?[.size] as? Int) ?? 0, (a?[.modificationDate] as? Date) ?? .distantPast)
  }

  private static func entry(_ path: String) -> Transcript {
    lock.withLock {
      let t = cache[path] ?? Transcript()
      cache[path] = t
      t.used = Date()
      return t
    }
  }

  static func agent(_ url: URL, stat known: (size: Int, modified: Date)? = nil) -> AgentStat {
    var info = known ?? stat(url)
    guard info.size > 0 else { return AgentStat() }
    let t = entry(url.path)
    t.lock.lock()
    defer { t.lock.unlock() }
    if t.offset > info.size, known != nil { info = stat(url) }
    if t.offset > info.size {
      t.reset()
      t.headed = false
      t.loop = nil
    } else if t.quiet, t.offset < info.size {
      t.reset()
    }
    if t.offset < info.size { t.consume(url) }
    if !t.quiet, t.offset == info.size, Date().timeIntervalSince(info.modified) > 30 * 60 { t.collapse() }
    return t.stat
  }

  static func loop(_ url: URL, size: Int) -> String? {
    let t = entry(url.path)
    t.lock.lock()
    defer { t.lock.unlock() }
    if t.headed { return t.loop }
    let found = Reader.groups(#"<command-name>/(loop-[a-z-]+)</command-name>"#, in: head(url)).first
    if found != nil || size >= 64 * 1024 {
      t.headed = true
      t.loop = found
    }
    return found
  }

  private struct Saved: Codable {
    struct Entry: Codable {
      var offset: Int
      var headed: Bool
      var loop: String?
      var first: Date?
      var last: Date?
      var model: String
      var acted: Bool
      var limited: Bool
      var billed: Double?
      var process: Int?
      var stat: AgentStat
    }

    struct Measured: Codable {
      var size: Int
      var modified: Date
      var process: Int?
      var billed: Double?
      var mine: Double
    }

    var version = 1
    var transcripts: [String: Entry] = [:]
    var samples: [String: Measured] = [:]
  }

  nonisolated(unsafe) static var caches = (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
    .appending(path: Bundle.main.bundleIdentifier ?? "Loops")
  nonisolated(unsafe) private static var savedAt = Date.distantPast

  static var encoder: JSONEncoder {
    let e = JSONEncoder()
    e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
    return e
  }

  static var decoder: JSONDecoder {
    let d = JSONDecoder()
    d.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
    return d
  }

  static func persist(force: Bool = false) {
    let now = Date()
    let saved: Saved? = lock.withLock {
      guard force || now.timeIntervalSince(savedAt) >= 300 else { return nil }
      savedAt = now
      var out = Saved()
      for (path, t) in cache {
        t.lock.lock()
        if t.quiet {
          out.transcripts[path] = Saved.Entry(
            offset: t.offset, headed: t.headed, loop: t.loop, first: t.first, last: t.last, model: t.model, acted: t.acted,
            limited: t.limited, billed: t.billed, process: t.process, stat: t.stat)
        }
        t.lock.unlock()
      }
      for (path, m) in samples {
        out.samples[path] = Saved.Measured(
          size: m.size, modified: m.modified, process: m.sample.process, billed: m.sample.billed, mine: m.sample.mine)
      }
      return out
    }
    guard let saved, let data = try? encoder.encode(saved) else { return }
    try? FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
    try? data.write(to: caches.appending(path: "spend.json"), options: .atomic)
  }

  static func restore() {
    guard let data = try? Data(contentsOf: caches.appending(path: "spend.json")),
      let saved = try? decoder.decode(Saved.self, from: data), saved.version == 1
    else { return }
    let now = Date()
    lock.withLock {
      for (path, e) in saved.transcripts where cache[path] == nil {
        let t = Transcript()
        t.offset = e.offset
        t.quiet = true
        t.headed = e.headed
        t.loop = e.loop
        t.first = e.first
        t.last = e.last
        t.model = e.model
        t.acted = e.acted
        t.limited = e.limited
        t.billed = e.billed
        t.process = e.process
        t.stat = e.stat
        t.used = now
        cache[path] = t
      }
      for (path, m) in saved.samples where samples[path] == nil {
        samples[path] = (m.size, m.modified, Sample(process: m.process, billed: m.billed, mine: m.mine), now)
      }
      savedAt = now
    }
  }

  private static func sweep(_ now: Date) {
    lock.withLock {
      cache = cache.filter { now.timeIntervalSince($0.value.used) < 3600 }
      journals = journals.filter { now.timeIntervalSince($0.value.used) < 3600 }
      metas = metas.filter { now.timeIntervalSince($0.value.used) < 3600 }
      samples = samples.filter { now.timeIntervalSince($0.value.used) < 3600 }
    }
  }

  static func label(_ name: String, _ input: [String: Any]) -> String {
    if name == "Bash", let c = input["command"] as? String { return command(c) }
    if let p = input["file_path"] as? String { return "\(name) \((p as NSString).lastPathComponent)" }
    if name.hasPrefix("mcp__") {
      return name.components(separatedBy: "__").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? name
    }
    return name
  }

  static func command(_ c: String) -> String {
    let skip = ["cd ", "export ", "set ", "#", "for ", "while ", "if ", "then", "else", "fi", "done", "echo "]
    let parts = c.split(whereSeparator: { "\n;&|".contains($0) })
      .map { p -> String in
        let t = p.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("do ") ? String(t.dropFirst(3)) : t
      }
    let main =
      parts.first { p in
        !p.isEmpty && !skip.contains { p.hasPrefix($0) } && p.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) == nil
      } ?? parts.first ?? c
    let words = main.split(separator: " ").map(String.init)
    guard let head = words.first.map({ ($0 as NSString).lastPathComponent }) else { return "a command" }
    if ["cat", "sed", "head", "tail", "nl", "less"].contains(head), let file = words.dropFirst().last(where: { !$0.hasPrefix("-") }) {
      return "\(head) \((file.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) as NSString).lastPathComponent)"
    }
    guard ["git", "gh", "bun", "bunx", "npx", "npm", "pnpm", "bash", "sh", "swift", "node"].contains(head) else { return head }
    var rest = words.dropFirst()
    while let w = rest.first, w.hasPrefix("-") {
      rest = rest.dropFirst(w == "-C" || w == "-c" ? 2 : 1)
    }
    return rest.first.map { "\(head) \(($0 as NSString).lastPathComponent)" } ?? head
  }

  private static let writes =
    #"git\b[^|;&\n]*\s(commit|push)\b|gh (pr|issue) (create|comment|review|edit|merge|close|reopen)\b|gh api\b[^|;&\n]*(-X ?(POST|PATCH|PUT|DELETE)|--method ?(POST|PATCH|PUT|DELETE)|\s-[fF]\s|--field|--raw-field|--input)"#

  static func acts(_ name: String, _ input: [String: Any]) -> Bool {
    switch name {
    case "Edit", "Write", "MultiEdit", "NotebookEdit":
      let p = (input["file_path"] as? String) ?? (input["notebook_path"] as? String) ?? ""
      return !(p.hasPrefix("/tmp/") || p.hasPrefix("/private/") || p.contains("/scratchpad/"))
    case "Bash":
      return (input["command"] as? String)?.range(of: writes, options: .regularExpression) != nil
    default:
      guard name.hasPrefix("mcp__"), let tool = name.components(separatedBy: "__").last else { return false }
      return tool.range(of: #"(^|_)(create|update|add|delete|set|remove|send|post|merge)(_|$)"#, options: .regularExpression) != nil
    }
  }

  private static func head(_ url: URL) -> String {
    guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
    defer { try? h.close() }
    return (try? h.read(upToCount: 64 * 1024)).map { String(decoding: $0, as: UTF8.self) } ?? ""
  }

  private enum Role { case main, judgment, reviewer, helper }

  private static func absorb(_ run: inout RunStat, _ a: AgentStat, _ role: Role) {
    switch role {
    case .main:
      run.main += a.tokens
      run.turns = a.turns
      run.model = a.model
      run.startup = a.startup
      run.limited = a.limited
    case .judgment:
      run.judgment += a.tokens
    case .reviewer:
      run.panel += a.tokens
      run.reviewers += 1
    case .helper:
      run.helpers += a.tokens
    }
    if role != .reviewer {
      run.acted = run.acted || a.acted
      run.outputs += a.outputs
    }
    run.agents += 1
    run.fixed += a.fixed
    run.fixedTokens += a.fixedTokens
    if let f = a.first, f < run.at { run.at = f }
    if let l = a.last, l > run.end { run.end = l }
  }

  private static func meta(_ file: URL, modified: Date) -> (parent: String?, loop: String?) {
    let url = file.deletingPathExtension().appendingPathExtension("meta.json")
    let now = Date()
    if let hit = lock.withLock({ () -> (parent: String?, loop: String?)? in
      guard let hit = metas[url.path], hit.modified == modified else { return nil }
      metas[url.path]?.used = now
      return (hit.parent, hit.loop)
    }) {
      return hit
    }
    let m = (try? Data(contentsOf: url)).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
    let found = (parent: m["parentAgentId"] as? String, loop: m["description"] as? String)
    lock.withLock { metas[url.path] = (modified, found.parent, found.loop, now) }
    return found
  }

  private static func id(_ file: URL) -> String {
    String(file.deletingPathExtension().lastPathComponent.dropFirst("agent-".count))
  }

  static func report(configs: [String], runner: URL, tasks: [(session: String, cwd: String)], now: Date) -> SpendReport {
    let since = now.addingTimeInterval(-7 * 86400)
    let today = day(now)
    let yesterday = day(now.addingTimeInterval(-86400))
    var r = SpendReport(loaded: true)
    var checks: [(code: Double, mine: Double)] = []
    func add(_ a: AgentStat, to i: Int, as role: Role) {
      absorb(&r.runs[i], a, role)
      r.todayLoops[r.runs[i].loop, default: Tokens()] += a.days[today] ?? Tokens()
      r.yesterday += a.days[yesterday] ?? Tokens()
    }
    for config in configs {
      let projects = URL(fileURLWithPath: config).appending(path: "projects/\(slug(runner.path))")
      let entries = listing(projects)
      let touched = Dictionary(
        entries.filter { $0.url.pathExtension == "jsonl" }.map { ($0.url.deletingPathExtension().lastPathComponent, $0.modified) },
        uniquingKeysWith: { a, _ in a })
      var byHand: [String: Int] = [:]
      for entry in entries where entry.url.pathExtension == "jsonl" && entry.modified >= since {
        let a = agent(entry.url, stat: entry.stat)
        guard let loop = loop(entry.url, size: entry.size) else {
          r.runner += a.days[today] ?? Tokens()
          r.yesterday += a.days[yesterday] ?? Tokens()
          continue
        }
        let session = entry.url.deletingPathExtension().lastPathComponent
        var run = RunStat(id: session, loop: loop, at: a.first ?? entry.modified, end: a.last ?? entry.modified)
        run.byHand = true
        run.finished = now.timeIntervalSince(entry.modified) > 120
        byHand[session] = r.runs.count
        r.runs.append(run)
        add(a, to: r.runs.count - 1, as: .main)
      }
      for entry in entries where entry.url.pathExtension.isEmpty {
        if let last = touched[entry.name], last < since.addingTimeInterval(-86400) { continue }
        var owner: [String: Int] = [:]
        for flow in listing(entry.url.appending(path: "subagents/workflows")) where flow.name.hasPrefix("wf_") {
          let journal = flow.url.appending(path: "journal.jsonl")
          let stamp = stat(journal)
          guard stamp.modified >= since else { continue }
          for (run, agents) in runs(flow.url, journal: journal, stamp: stamp, now: now) {
            r.runs.append(run)
            let i = r.runs.count - 1
            for (id, role, a) in agents {
              owner[id] = i
              add(a, to: i, as: role)
            }
          }
        }
        var pending: [(id: String, parent: String?, file: File)] = []
        let subagents = listing(entry.url.appending(path: "subagents"))
        let stamps = Dictionary(subagents.map { ($0.name, $0.modified) }, uniquingKeysWith: { a, _ in a })
        for f in subagents where f.url.pathExtension == "jsonl" && f.modified >= since {
          let m = meta(f.url, modified: stamps[f.url.deletingPathExtension().appendingPathExtension("meta.json").lastPathComponent] ?? .distantPast)
          if let i = byHand[entry.name], m.parent == nil {
            owner[id(f.url)] = i
            add(agent(f.url, stat: f.stat), to: i, as: .helper)
          } else if m.parent == nil, let loop = m.loop, loop.hasPrefix("loop-"), !loop.contains(" ") {
            let a = agent(f.url, stat: f.stat)
            var run = RunStat(id: "\(entry.name):\(id(f.url))", loop: loop, at: a.first ?? f.modified, end: a.last ?? f.modified)
            run.finished = now.timeIntervalSince(f.modified) > 300
            r.runs.append(run)
            owner[id(f.url)] = r.runs.count - 1
            add(a, to: r.runs.count - 1, as: .main)
          } else {
            pending.append((id(f.url), m.parent, f))
          }
        }
        var progress = true
        while progress && !pending.isEmpty {
          progress = false
          pending.removeAll { p in
            guard let parent = p.parent, let i = owner[parent] else { return false }
            owner[p.id] = i
            add(agent(p.file.url, stat: p.file.stat), to: i, as: .helper)
            progress = true
            return true
          }
        }
        for p in pending {
          let a = agent(p.file.url, stat: p.file.stat)
          r.runner += a.days[today] ?? Tokens()
          r.yesterday += a.days[yesterday] ?? Tokens()
        }
      }
      for t in tasks {
        let a = agent(URL(fileURLWithPath: config).appending(path: "projects/\(slug(t.cwd))/\(t.session).jsonl"))
        let spent = a.days[today] ?? Tokens()
        r.tasks += a.billed.map { b in spent.scaled(a.tokens.cost > 0 ? b / a.tokens.cost : 1) } ?? spent
      }
      checks += calibration(entries, since: now.addingTimeInterval(-30 * 86400), now: now)
    }
    if !checks.isEmpty {
      r.samples = checks.count
      r.factor = checks.map(\.code).reduce(0, +) / checks.map(\.mine).reduce(0, +)
      for i in r.runs.indices { r.runs[i].scale(r.factor) }
      r.todayLoops = r.todayLoops.mapValues { $0.scaled(r.factor) }
      r.runner = r.runner.scaled(r.factor)
      r.yesterday = r.yesterday.scaled(r.factor)
    }
    r.today = r.todayLoops.values.reduce(r.runner + r.tasks, +)
    r.runs.sort { $0.at < $1.at }
    sweep(now)
    return r
  }

  private static func calibration(_ entries: [File], since: Date, now: Date) -> [(code: Double, mine: Double)] {
    var byProcess: [Int: (code: Double, mine: Double, done: Bool)] = [:]
    for entry in entries where entry.url.pathExtension == "jsonl" && entry.modified >= since {
      let done = now.timeIntervalSince(entry.modified) > 30 * 60
      let sample = done ? cached(entry, now: now) ?? measured(entry, keep: true, now: now) : measured(entry, keep: false, now: now)
      guard let process = sample.process, let billed = sample.billed else { continue }
      var e = byProcess[process] ?? (0, 0, true)
      e.code = max(e.code, billed)
      e.mine += sample.mine
      e.done = e.done && done
      byProcess[process] = e
    }
    return byProcess.values
      .filter { $0.done && $0.mine >= 0.5 && (0.9...2.5).contains($0.code / $0.mine) }
      .map { ($0.code, $0.mine) }
  }

  private static func cached(_ entry: File, now: Date) -> Sample? {
    lock.withLock {
      guard let hit = samples[entry.url.path], hit.size == entry.size, hit.modified == entry.modified else { return nil }
      samples[entry.url.path]?.used = now
      return hit.sample
    }
  }

  private static func measured(_ entry: File, keep: Bool, now: Date) -> Sample {
    let a = agent(entry.url, stat: entry.stat)
    var sample = Sample(process: a.process, billed: a.billed)
    if a.process != nil, a.billed != nil {
      let dir = entry.url.deletingPathExtension()
      sample.mine = a.tokens.cost
      for f in listing(dir.appending(path: "subagents")) where f.url.pathExtension == "jsonl" {
        sample.mine += agent(f.url, stat: f.stat).tokens.cost
      }
      for flow in listing(dir.appending(path: "subagents/workflows")) {
        for f in listing(flow.url) where f.url.pathExtension == "jsonl" && f.name.hasPrefix("agent-") {
          sample.mine += agent(f.url, stat: f.stat).tokens.cost
        }
      }
    }
    if keep { lock.withLock { samples[entry.url.path] = (entry.size, entry.modified, sample, now) } }
    return sample
  }

  private static func journal(_ url: URL, stamp: (size: Int, modified: Date)) -> Journal {
    let now = Date()
    if let hit = lock.withLock({ () -> Journal? in
      guard let hit = journals[url.path], hit.size == stamp.size, hit.modified == stamp.modified else { return nil }
      journals[url.path]?.used = now
      return hit.journal
    }) {
      return hit
    }
    var j = Journal()
    for line in (Reader.text(url) ?? "").split(separator: "\n") {
      guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
        let id = obj["agentId"] as? String
      else { continue }
      switch obj["type"] as? String {
      case "started": j.order.append((id, obj["label"] as? String ?? ""))
      case "result":
        j.done.insert(id)
        let result = obj["result"]
        if let brief = (result as? [String: Any])?["brief"] as? String ?? result as? String { j.briefs[id] = brief } else { j.briefs[id] = nil }
      case "failed": j.failed.insert(id)
      default: break
      }
    }
    lock.withLock { journals[url.path] = (stamp.size, stamp.modified, j, now) }
    return j
  }

  private static func runs(_ flow: URL, journal url: URL, stamp: (size: Int, modified: Date), now: Date) -> [(
    RunStat, [(String, Role, AgentStat)]
  )] {
    let j = journal(url, stamp: stamp)
    let files = Dictionary(listing(flow).map { ($0.name, $0.stat) }, uniquingKeysWith: { a, _ in a })
    var out: [(RunStat, [(String, Role, AgentStat)])] = []
    var index: [String: Int] = [:]
    for (id, label) in j.order {
      let parts = label.split(separator: ":").map(String.init)
      guard let loop = parts.first, loop.hasPrefix("loop-") else { continue }
      if index[loop] == nil {
        index[loop] = out.count
        out.append((RunStat(id: "\(flow.lastPathComponent):\(loop)", loop: loop, at: .distantFuture, end: .distantPast), []))
      }
      let i = index[loop]!
      let name = "agent-\(id).jsonl"
      let a = agent(flow.appending(path: name), stat: files[name] ?? (0, .distantPast))
      let role: Role = parts.count == 1 ? .main : parts[1] == "judgment" ? .judgment : .reviewer
      out[i].1.append((id, role, a))
      let finished = j.done.contains(id)
      let brief = j.briefs[id]
      switch role {
      case .main:
        let stale = now.timeIntervalSince(a.last ?? stamp.modified) > 30 * 60
        out[i].0.failed = j.failed.contains(id) || (!finished && stale)
        out[i].0.finished = finished || out[i].0.failed
        out[i].0.brief = brief
      case .judgment:
        if !finished && !j.failed.contains(id) { out[i].0.finished = false }
        if let brief { out[i].0.brief = brief }
      case .reviewer, .helper:
        break
      }
    }
    for i in out.indices where out[i].1.allSatisfy({ $0.2.first == nil }) {
      out[i].0.at = stamp.modified
      out[i].0.end = stamp.modified
    }
    return out
  }
}

enum AdviceAction {
  case ask(String, prompt: String, done: String? = nil)
  case model(String)
  case retro
}

struct Advice: Identifiable {
  let id: String
  let loop: String?
  let symbol: String
  let title: String
  let detail: String
  let saving: Double?
  var tokens: Int? = nil
  var reads = false
  var badge: String? = nil
  let action: AdviceAction?
}

extension Advice {
  var label: String {
    if let badge { return badge }
    guard let saving else { return "" }
    switch tokens {
    case 0?: return "same tokens · saves ~\(saving.usd)/wk"
    case let t?: return "saves ~\(t.compact) tokens\(reads ? " read" : "") · ~\(saving.usd)/wk"
    case nil: return "saves ~\(saving.usd)/wk"
    }
  }
}

struct LoopPerf {
  let loop: String
  let title: String
  let runs: [RunStat]

  var done: [RunStat] { runs.filter(\.finished) }
  var tokens: Tokens { runs.map(\.tokens).reduce(Tokens(), +) }
  var cost: Double { tokens.cost }
  var quiet: [RunStat] { done.filter(\.quiet) }
  var failed: [RunStat] { done.filter { $0.failed && !$0.limited } }
  var acted: [RunStat] { done.filter { $0.acted && !$0.failed } }
  var perRun: Double { done.isEmpty ? 0 : done.map(\.tokens.cost).reduce(0, +) / Double(done.count) }
  var minutes: Double { Self.median(done.map(\.minutes)) }
  var longest: Double { done.map(\.minutes).max() ?? 0 }
  var turns: Int { Int(Self.median(done.map { Double($0.turns) })) }
  var runTokens: Int { Int(Self.median(done.map { Double($0.tokens.total) })) }
  var startup: Int { Int(Self.median(runs.map { Double($0.startup) }.filter { $0 > 0 })) }
  var panel: Double { runs.map { $0.panel.cost }.reduce(0, +) }
  var reviewers: Double {
    let paneled = runs.filter { $0.reviewers > 0 }
    return paneled.isEmpty ? 0 : Double(paneled.map(\.reviewers).reduce(0, +)) / Double(paneled.count)
  }

  static func median(_ xs: [Double]) -> Double {
    let s = xs.sorted()
    guard !s.isEmpty else { return 0 }
    return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
  }

  func advice(model: String) -> [Advice] {
    var out: [Advice] = []
    let skill = ".claude/skills/\(loop)/SKILL.md"

    let q = quiet
    let quietCost = q.map(\.tokens.cost).reduce(0, +)
    if q.count >= 2, quietCost >= 0.25 {
      let each = Int(Self.median(q.map { Double($0.tokens.total) }))
      let mostlyStartup = startup > 0 && Double(startup) >= Double(each) * 0.5
      out.append(
        Advice(
          id: "\(loop):quiet", loop: loop, symbol: "moon.zzz",
          title: "\(q.count) of \(done.count) runs found nothing",
          detail:
            "They cost \(quietCost.usd), about \(each.compact) tokens each\(mostlyStartup ? ", mostly setup" : ""). A cheap pre-check, such as whether anything changed since its last run, would skip them.",
          saving: quietCost, tokens: q.map(\.tokens.total).reduce(0, +),
          action: .ask(
            "Ask Claude to add a pre-check",
            prompt:
            "The loop \(loop) (\(title)) ran \(done.count) times in the last 7 days, and \(q.count) of those runs changed nothing, costing \(quietCost.usd) at API prices, about \(each.compact) tokens each. Design a cheap check the runner makes before it starts this loop's agent, such as comparing what the loop watches with the sha in its state, and skip the run when nothing changed. Read the loops plugin's skills/runner/SKILL.md, workflows/tick.js and bin/loop-runner (`loop-runner kit` prints where it lives) and \(skill) first. Open a pull request.", done: Goal.pullRequest)
        ))
    }

    let failedCost = failed.map(\.tokens.cost).reduce(0, +)
    if !failed.isEmpty {
      let when = failed.suffix(3).map { Clock.day($0.at, now: .now) }
      out.append(
        Advice(
          id: "\(loop):failed", loop: loop, symbol: "exclamationmark.triangle",
          title: failed.count == 1 ? "A run ended without a result" : "\(failed.count) runs ended without a result",
          detail:
            "\(joined(when)) left no brief or state, so \(failedCost.usd) bought nothing. A retro finds where it stops.",
          saving: failedCost, badge: "\(failed.map(\.tokens.total).reduce(0, +).compact) tokens · \(failedCost.usd) lost",
          action: .retro
        ))
    }

    let outputs = runs.flatMap(\.outputs)
    let reread = outputs.map(\.reread).reduce(0, +)
    if cost > 0, reread >= 0.5, reread / cost >= 0.15 {
      var byWhat: [String: (cost: Double, tokens: Int, later: Int)] = [:]
      for o in outputs {
        let e = byWhat[o.what] ?? (0, 0, 0)
        byWhat[o.what] = (e.cost + o.reread, max(e.tokens, o.tokens), max(e.later, o.later))
      }
      let named = byWhat.sorted { $0.value.cost > $1.value.cost }.prefix(3)
        .map { "`\($0.key)` (\($0.value.tokens.compact) tokens, re-read \($0.value.later) times)" }
      let files = outputs.filter(\.file).map(\.reread).reduce(0, +) / reread >= 0.5
      let fix = files ? "Reading only the lines it needs would cut it." : "Tail or grep the output instead."
      out.append(
        Advice(
          id: "\(loop):reread", loop: loop, symbol: "arrow.trianglehead.2.clockwise.rotate.90",
          title: files ? "Re-reads the files it opened" : "Re-reads long command output",
          detail:
            "Early output is paid for again on every later turn: \(reread.usd), \(Int(reread / cost * 100))% of its spend. Biggest: \(named.first ?? ""). \(fix)",
          saving: reread / 2, tokens: outputs.map { $0.tokens * $0.later }.reduce(0, +) / 2, reads: true,
          action: .ask(
            "Ask Claude to trim it",
            prompt:
            "In the loop \(loop)'s runs over the last 7 days, tool output re-read on later turns cost \(reread.usd) at API prices, \(Int(reread / cost * 100))% of its spend. The biggest: \(joined(named)). Change \(skill), and any script it calls, so that output stays out of the main conversation: read only the lines it needs, tail or grep command output, or hand broad reading to a helper agent that returns a summary. Open a pull request.", done: Goal.pullRequest)
        ))
    }

    if cost > 0, panel / cost >= 0.5, reviewers >= 4 {
      out.append(
        Advice(
          id: "\(loop):panel", loop: loop, symbol: "person.3",
          title: "Reviews cost more than the work",
          detail:
            "\(Int(panel / cost * 100))% of its spend goes to \(Int(reviewers.rounded())) reviewers a run, each reading the whole diff. Size the panel to the change.",
          saving: nil, badge: "\(runs.map(\.panel.total).reduce(0, +).compact) tokens · \(panel.usd)/wk on reviews",
          action: .ask(
            "Ask Claude to size the panel",
            prompt:
            "The loop \(loop)'s review panel took \(Int(panel / cost * 100))% of its spend over the last 7 days (\(panel.usd) of \(cost.usd) at API prices), with about \(Int(reviewers.rounded())) reviewers a run, each reading the whole diff. Change how the loop picks its panel (\(skill) and .claude/loops/panel.md) so the number and kind of lenses scale with the size and risk of the change. Open a pull request.", done: Goal.pullRequest)
        ))
    }

    if model == "fable" {
      let fable = done.map(\.main.cost).reduce(0, +)
      let opus = done.map { Price.reprice($0.main, as: "opus") }.reduce(0, +)
      if fable - opus >= 0.5 {
        out.append(
          Advice(
            id: "\(loop):model", loop: loop, symbol: "cpu",
            title: "Opus is \(String(format: "%.1f", fable / max(opus, 0.01)))× cheaper",
            detail:
              "The same tokens on Opus 5.5: \(opus.usd) instead of \(fable.usd) this week. Switching opens a PR; Fable stays until you merge it.",
            saving: fable - opus, tokens: 0,
            action: .model("opus")
          ))
      }
    }

    return out
  }
}
