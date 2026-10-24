import Foundation

struct LoopSpec: Identifiable, Hashable {
  let name: String
  let title: String
  let every: Int
  let from: Int?
  let until: Int?
  let alone: Bool
  var group: String? = nil
  var zone: TimeZone = .current
  var ships: String? = nil
  var symbol: String? = nil

  var id: String { name }
  static func short(_ name: String) -> String { name.hasPrefix("loop-") ? String(name.dropFirst(5)) : name }
  var weekly: Bool { every >= 168 }

  var cadence: String { LoopSpec.cadence(every) }

  var window: String? {
    guard let from, let until else { return nil }
    return String(format: "%02d:00–%02d:00", from, until)
  }
}

struct LoopState {
  let at: Date?
  let sha: String?
  let json: String
  let raw: [String: Any]
}

struct Brief: Identifiable, Hashable {
  let id: Int
  let at: Date
  let loop: String
  let text: String
}

struct Ask: Identifiable, Hashable {
  let id: String
  let loop: String
  let text: String
  let url: URL?
  let at: Date
}

struct RunnerState: Decodable {
  struct Account: Decodable, Hashable, Identifiable {
    let dir: String
    let email: String?
    let limitedAt: Double?
    let limit: String?
    let own: Bool?

    var id: String { dir }
    var name: String { email ?? dir }
  }

  struct Session: Decodable {
    let id: String?
    let state: String?
    let waitingFor: String?

    enum Key: String, CodingKey { case id, state, waitingFor }

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: Key.self)
      id = try? c.decode(String.self, forKey: .id)
      state = try? c.decode(String.self, forKey: .state)
      if let s = try? c.decode(String.self, forKey: .waitingFor) {
        waitingFor = s
      } else if c.contains(.waitingFor), (try? c.decodeNil(forKey: .waitingFor)) == false {
        waitingFor = "input"
      } else {
        waitingFor = nil
      }
    }
  }

  let account: String
  let accounts: [Account]
  let useShared: Bool?
  let session: Session?
  let limited: Bool
  let watching: Bool
  let busy: [String]
}

struct Paths {
  let repo: URL

  var common: URL { repo.appending(path: ".git") }
  var runner: URL { repo.appending(path: ".claude/worktrees/loop-runner") }
  var loops: URL { runner.appending(path: ".claude/loops") }
  var locks: URL { common.appending(path: "loop-locks") }
  var paused: URL { common.appending(path: "loop-paused") }
  var config: URL { runner.appending(path: ".claude/loops.json") }
  var script: URL { Paths.bin.appending(path: "loop-runner") }

  static let bin: URL =
    Bundle.main.resourceURL.map { $0.appending(path: "bin") }.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    ?? URL(fileURLWithPath: (Bundle.main.infoDictionary?["LoopsBin"] as? String) ?? "/nonexistent")

  func skill(_ loop: String) -> URL { runner.appending(path: ".claude/skills/\(loop)/SKILL.md") }

  func contains(_ cwd: String?) -> Bool {
    guard let cwd else { return false }
    return cwd == repo.path || cwd.hasPrefix(repo.path + "/")
  }

  func tool(_ name: String) -> URL? {
    let url = Paths.bin.appending(path: name)
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
  }

  func find(_ relative: String) -> URL? {
    let fm = FileManager.default
    let trees = ((try? fm.contentsOfDirectory(at: repo.appending(path: ".claude/worktrees"), includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
      .sorted {
        ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
          > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
      }
    return ([runner, repo] + trees).map { $0.appending(path: relative) }.first { fm.fileExists(atPath: $0.path) }
  }
}

struct ProjectConfig: Decodable, Equatable {
  struct Loop: Decodable, Equatable {
    let name: String
    let title: String?
    let group: String?
    let every: Int
    let hours: [Int]?
    let alone: Bool?
    let ships: String?
    let symbol: String?
  }

  struct GateStep: Decodable, Equatable {
    let name: String
    let run: String
  }

  struct CI: Decodable, Equatable {
    let workflow: String?
    let label: String?
  }

  let name: String?
  let about: String?
  let timezone: String?
  let ci: CI?
  let gate: [GateStep]?
  let loops: [Loop]?

  var zone: TimeZone { timezone.flatMap(TimeZone.init(identifier:)) ?? .current }

  var specs: [LoopSpec] {
    (loops ?? []).map { l in
      LoopSpec(
        name: l.name, title: l.title ?? LoopSpec.short(l.name), every: l.every, from: l.hours?.first, until: l.hours?.dropFirst().first,
        alone: l.alone ?? false, group: l.group, zone: zone, ships: l.ships, symbol: l.symbol)
    }
  }

  static func read(_ url: URL) -> ProjectConfig? {
    (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(ProjectConfig.self, from: $0) }
  }
}

struct Registry: Decodable {
  struct Project: Decodable {
    let own: [String]?
    let useShared: Bool?
  }

  let shared: [String]?
  let projects: [String: Project]?

  var accounts: [String] { (shared ?? []) + (projects ?? [:]).values.flatMap { $0.own ?? [] } }

  static var url: URL {
    let env = ProcessInfo.processInfo.environment["LOOPS_HOME"]
    return (env.map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".loops"))
      .appending(path: "config.json")
  }

  static func read(_ url: URL = Registry.url) -> Registry? {
    (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Registry.self, from: $0) }
  }
}

enum Reader {
  private static let iso = ISO8601DateFormatter()
  private static let isoFraction: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()

  static func date(_ s: String) -> Date? { iso.date(from: s) ?? isoFraction.date(from: s) }

  static func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

  static func groups(_ pattern: String, in s: some StringProtocol) -> [String] {
    guard let re = try? Regex(pattern), let m = String(s).firstMatch(of: re) else { return [] }
    return m.output.dropFirst().compactMap { $0.substring.map(String.init) }
  }


  static func states(_ dir: URL) -> [String: LoopState] {
    let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    var out: [String: LoopState] = [:]
    for f in files where f.pathExtension == "json" {
      guard let data = try? Data(contentsOf: f) else { continue }
      let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
      let pretty =
        obj.flatMap {
          try? JSONSerialization.data(withJSONObject: $0, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        }
        .map { String(decoding: $0, as: UTF8.self) } ?? String(decoding: data, as: UTF8.self)
      out[f.deletingPathExtension().lastPathComponent] = LoopState(
        at: (obj?["at"] as? String).flatMap(date), sha: obj?["sha"] as? String, json: pretty, raw: obj ?? [:])
    }
    return out
  }

  static func briefs(_ url: URL) -> [Brief] {
    guard let log = text(url) else { return [] }
    var out: [Brief] = []
    var head: (at: Date, loop: String)?
    var body: [Substring] = []
    func flush() {
      guard let head else { return }
      let text = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      out.append(Brief(id: out.count, at: head.at, loop: head.loop, text: text))
    }
    for line in log.split(separator: "\n", omittingEmptySubsequences: false) {
      let g = line.hasPrefix("## ") ? groups(#"^## (\S+) (loop-[\w-]+)\s*$"#, in: line) : []
      if g.count == 2, let at = date(g[0]) {
        flush()
        head = (at, g[1])
        body = []
      } else {
        body.append(line)
      }
    }
    flush()
    return out
  }

  static func running(_ dir: URL, now: Date) -> [String: Date] {
    let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
    let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
    var out: [String: Date] = [:]
    for d in items where !d.lastPathComponent.hasPrefix(".") {
      let v = try? d.resourceValues(forKeys: Set(keys))
      guard v?.isDirectory == true, let m = v?.contentModificationDate, now.timeIntervalSince(m) < 180 * 60
      else { continue }
      let by = text(d.appending(path: "by")) ?? ""
      out[d.lastPathComponent] = by.split(separator: " ").first.flatMap { date(String($0)) } ?? m
    }
    return out
  }

  static func paused(_ dir: URL) -> Set<String> {
    Set(((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") })
  }

  static func description(_ url: URL) -> String? {
    guard let s = text(url) else { return nil }
    for line in s.split(separator: "\n").prefix(20) where line.hasPrefix("description:") {
      return line.dropFirst("description:".count)
        .trimmingCharacters(in: .whitespaces)
        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }
    return nil
  }

  static func tail(_ url: URL, _ n: Int) -> [String] {
    guard let s = text(url) else { return [] }
    return s.split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(n)
  }
}
