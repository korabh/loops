import Foundation
import Observation
import SwiftUI

struct Direction: Codable, Equatable, Identifiable {
  enum Rung: String, Codable, CaseIterable {
    case watch, teach, `guard`, reshape

    var title: String {
      switch self {
      case .watch: "Watch"
      case .teach: "Teach"
      case .guard: "Guard"
      case .reshape: "Reshape"
      }
    }

    var builds: String {
      switch self {
      case .watch: "nothing yet, only keep counting the signal"
      case .teach: "a rule plus the check that enforces it"
      case .guard: "a test or a hook"
      case .reshape: "a spec that changes structure"
      }
    }

    var symbol: String {
      switch self {
      case .watch: "eye"
      case .teach: "text.book.closed"
      case .guard: "shield"
      case .reshape: "square.stack.3d.up"
      }
    }
  }

  let question: String
  let evidence: [String]
  let gap: String
  let rung: Rung
  let notYet: String

  var id: String { question }

  var evidenceCount: Int {
    evidence.map { Int(Reader.groups(#"^\s*(\d+)\s"#, in: $0).first ?? "") ?? 1 }.reduce(0, +)
  }

  func idea(destination: String) -> String {
    """
    \(question)

    Evidence: \(evidence.joined(separator: "; ")).
    Gap to the destination ("\(destination)"): \(gap)
    Rung: \(rung.title), which builds \(rung.builds).
    Not yet: \(notYet)

    The spec builds no more than the \(rung.title) rung: \(rung.builds). Anything past it goes under Out of Scope.
    """
  }
}

struct Dismissal: Codable, Equatable {
  let question: String
  let reason: String
  let evidenceCount: Int
  let at: Date
}

struct Needed: Decodable, Equatable {
  let last7: Int
  let prior7: Int
}

struct Records: Decodable {
  let needed: Needed
}

struct Answer: Codable {
  let at: String
  let loop: String?
  let task: String
  let question: String
  let answer: String
  let source: String
}

@MainActor @Observable
final class Directions {
  static let shared = Directions()

  static let defaultDestination = "A loop merges its own two-way-door PR, and I review it after it lands."
  static let budget = 5

  private(set) var list: [Direction] = []
  private(set) var at: Date?
  private(set) var usage: Usage?
  private(set) var fingerprint: String?
  private(set) var basis: String?
  private(set) var dismissed: [Dismissal] = []
  private(set) var needed: Needed?
  private(set) var uncounted: String?
  private(set) var busy = false
  private(set) var since: Date?
  private(set) var failure: String?
  private(set) var destination: String

  private static let listKey = "directions"
  private static let atKey = "directionsAt"
  private static let usageKey = "directionsUsage"
  private static let fingerprintKey = "directionsFingerprint"
  private static let basisKey = "directionsDestination"
  private static let dismissedKey = "dismissedDirections"
  private static let destinationKey = "destination"

  private static let schema =
    #"{"type":"object","additionalProperties":false,"required":["directions"],"properties":{"directions":{"type":"array","maxItems":3,"items":{"type":"object","additionalProperties":false,"required":["question","evidence","gap","rung","notYet"],"properties":{"question":{"type":"string"},"evidence":{"type":"array","items":{"type":"string"}},"gap":{"type":"string"},"rung":{"type":"string","enum":["watch","teach","guard","reshape"]},"notYet":{"type":"string"}}}}}}"#

  private init() {
    let d = UserDefaults.standard
    if let data = d.data(forKey: Self.listKey), let saved = try? JSONDecoder().decode([Direction].self, from: data) { list = saved }
    at = d.object(forKey: Self.atKey) as? Date
    usage = d.data(forKey: Self.usageKey).flatMap { try? JSONDecoder().decode(Usage.self, from: $0) }
    fingerprint = d.string(forKey: Self.fingerprintKey)
    basis = d.string(forKey: Self.basisKey)
    dismissed = d.data(forKey: Self.dismissedKey).flatMap { try? JSONDecoder().decode([Dismissal].self, from: $0) } ?? []
    destination = d.string(forKey: Self.destinationKey) ?? Self.defaultDestination
  }

  var goal: String {
    let d = destination.trimmingCharacters(in: .whitespacesAndNewlines)
    return d.isEmpty ? Self.defaultDestination : d
  }

  var destinationBinding: Binding<String> {
    Binding(
      get: { self.destination },
      set: {
        self.destination = $0
        UserDefaults.standard.set($0, forKey: Self.destinationKey)
      })
  }

  var visible: [Direction] { Self.unseen(list, dismissed: dismissed) }

  nonisolated static func unseen(_ list: [Direction], dismissed: [Dismissal]) -> [Direction] {
    list.filter { d in
      guard let gone = dismissed.last(where: { same($0.question, d.question) }) else { return true }
      return d.evidenceCount > gone.evidenceCount
    }
  }

  func stale(_ seen: String) -> Bool { at != nil && (fingerprint != seen || (basis ?? Self.defaultDestination) != goal) }

  static func fingerprint(_ paths: Paths) -> String {
    ["notes.md", "log.md", "answers.jsonl"].map { name in
      let a = try? FileManager.default.attributesOfItem(atPath: paths.loops.appending(path: name).path)
      let size = (a?[.size] as? Int) ?? 0
      let modified = (a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
      return "\(name):\(size):\(Int(modified))"
    }.joined(separator: "|")
  }

  private nonisolated static func same(_ a: String, _ b: String) -> Bool {
    a.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(b.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
  }

  private func signals(_ paths: Paths) async -> (records: String?, problem: String?) {
    guard let script = paths.tool("loop-directions") else { return (nil, "This build of Loops has no loop-directions.") }
    let (code, out) = await Shell.exec(["bash", script.path, paths.runner.path], in: paths.repo)
    guard code == 0, let start = out.firstIndex(of: "{"), let end = out.lastIndex(of: "}") else {
      return (nil, out.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init) ?? "loop-directions returned nothing.")
    }
    let json = String(out[start...end])
    if let r = try? JSONDecoder().decode(Records.self, from: Data(json.utf8)) { needed = r.needed }
    return (json, nil)
  }

  func count(store: Store) async {
    guard !busy else { return }
    uncounted = await signals(store.paths).problem
  }

  func ask(store: Store) {
    guard !busy else { return }
    busy = true
    since = Date()
    failure = nil
    let paths = store.paths
    let config = store.config
    let held = heldSignals(store)
    let aim = goal
    Task {
      defer { busy = false }
      let seen = Self.fingerprint(paths)
      let (found, problem) = await signals(paths)
      uncounted = problem
      guard let records = found else {
        failure = problem
        return
      }
      let (_, out) = await Shell.exec(
        [
          "claude", "-p", "--model", "fable", "--effort", "medium", "--tools", "Read,Grep,Glob", "--no-session-persistence",
          "--max-budget-usd", String(Self.budget), "--disable-slash-commands", "--output-format", "json", "--json-schema", Self.schema,
          prompt(records: records, held: held, destination: aim),
        ], in: Planner.home(paths), config: config)
      let json = out.split(separator: "\n").last { $0.hasPrefix("{") }.map(String.init) ?? ""
      guard let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else {
        failure = out.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init) ?? "Claude Code returned nothing."
        return
      }
      guard let s = obj["structured_output"], let data = try? JSONSerialization.data(withJSONObject: s),
        let directions = (try? JSONDecoder().decode([String: [Direction]].self, from: data))?["directions"]
      else {
        failure =
          obj["subtype"] as? String == "error_max_budget_usd"
          ? "Claude stopped at its $\(Self.budget) cap before it returned any directions."
          : (obj["result"] as? String).map { String($0.prefix(300)) } ?? "Claude Code returned no directions."
        return
      }
      list = Array(directions.prefix(3))
      at = Date()
      usage = Usage(result: obj)
      fingerprint = seen
      basis = aim
      let d = UserDefaults.standard
      d.set(try? JSONEncoder().encode(list), forKey: Self.listKey)
      d.set(at, forKey: Self.atKey)
      d.set(try? JSONEncoder().encode(usage), forKey: Self.usageKey)
      d.set(seen, forKey: Self.fingerprintKey)
      d.set(aim, forKey: Self.basisKey)
    }
  }

  func dismiss(_ d: Direction, reason: String) {
    dismissed.removeAll { Self.same($0.question, d.question) }
    dismissed.append(
      Dismissal(question: d.question, reason: reason.trimmingCharacters(in: .whitespacesAndNewlines), evidenceCount: d.evidenceCount, at: Date()))
    UserDefaults.standard.set(try? JSONEncoder().encode(dismissed), forKey: Self.dismissedKey)
  }

  func explore(_ d: Direction, store: Store) {
    Planner.shared.start(d.idea(destination: basis ?? Self.defaultDestination), store: store)
  }

  private func heldSignals(_ store: Store) -> String {
    var lines: [String] = []
    let short = store.tasks.filter { $0.goal != nil && !$0.active && !$0.goalMet && $0.limit == nil }.prefix(8)
    if !short.isEmpty {
      lines.append("Goals that fell short:")
      lines += short.map { "- \($0.title.replacingOccurrences(of: "Goal: ", with: "")): \($0.goal?.reason ?? "it ended before the goal was met")" }
    }
    let reviews = store.briefs.filter { $0.loop == "loop-pr-review" }.suffix(8)
    if !reviews.isEmpty {
      lines.append("Latest PR-review results:")
      lines += reviews.map { "- \(Clock.day($0.at, now: store.now)): \(Briefs.body($0).replacingOccurrences(of: "\n", with: " "))" }
    }
    return lines.joined(separator: "\n")
  }

  private func prompt(records: String, held: String, destination: String) -> String {
    let passed =
      dismissed.isEmpty
      ? "None."
      : dismissed.map { "- \"\($0.question)\" (evidence count \($0.evidenceCount)), dismissed because: \($0.reason)" }.joined(separator: "\n")
    let rungs = Direction.Rung.allCases.map { "\($0.rawValue) (\($0.builds))" }.joined(separator: ", ")
    return """
      The person running this repo's loops works backwards from one destination: "\(destination)"

      Below is what the loops have recorded in the last four weeks: every time a brief needed the person (each deep link, numbered item or "Needs a person" and "Decision" line), the answers the person gave waiting sessions and Waiting on you items, the loops' shared notes grouped by area, and each loop's newest lessons. After it come signals only the Loops app holds.

      Group these records into signals and return up to three directions: questions the person is not asking, each one technical (architecture, tests, tooling, or what the loops know), never a product feature. Raise a direction only when its signal recurs or it closes a gap between today and the destination; a one-off is not a direction. When nothing qualifies, return an empty list rather than inventing one.

      Before you raise a direction, check each claim it makes against the code with Read, Grep and Glob, so a count of callers or files is the real count.

      For each direction give:
      - question: the question the person isn't asking, one or two sentences ending in a question mark.
      - evidence: the counted signals behind it, each string starting with its count as digits followed by a space, like "9 notes tagged [availability] in 2 days".
      - gap: which gap between today and the destination it closes.
      - rung: the lowest rung that stops the signal recurring, one of: \(rungs).
      - notYet: what it deliberately leaves out.

      The person dismissed these directions before. Raise one again only when its evidence count is now higher, and then reuse its question word for word:
      \(passed)

      Records from the loops (JSON):
      \(records)

      \(held)
      """
  }
}

extension Store {
  func recordAnswer(loop: String?, task: String, question: String, answer: String, source: String) {
    let entry = Answer(
      at: ISO8601DateFormatter().string(from: Date()), loop: loop, task: task, question: question, answer: answer, source: source)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    guard var line = try? encoder.encode(entry) else { return }
    line.append(0x0A)
    let url = paths.loops.appending(path: "answers.jsonl")
    let fm = FileManager.default
    if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
    guard let h = try? FileHandle(forWritingTo: url) else { return }
    defer { try? h.close() }
    _ = try? h.seekToEnd()
    try? h.write(contentsOf: line)
  }
}
