import SwiftUI

struct TaskGoal: Codable, Equatable {
  enum Verdict: String, Codable {
    case working, met, impossible
  }

  let done: String
  let turns: Int
  var verdict: Verdict?
  var taken = 0
  var reason: String?

  var resolved: Bool { verdict == .met || verdict == .impossible }
}

enum Goal {
  static let limit = 4000
  static let turns = 20
  static let pullRequest = "a pull request with the change is open and its URL is in the final message"

  static func condition(_ task: String, done: String, turns: Int) -> String {
    var head = task.trimmingCharacters(in: .whitespacesAndNewlines)
    if let last = head.last, !".!?".contains(last) { head += "." }
    let end = done.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
    return "\(head) Done when \(end). If that is not true within \(turns) turns, the goal is impossible."
      .split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }

  static func command(_ task: String, goal: TaskGoal) -> String? {
    let text = condition(task, done: goal.done, turns: goal.turns)
    return text.count <= limit ? "/goal \(text)" : nil
  }
}

@MainActor
enum GoalLog {
  private static var cache: [String: (offset: UInt64, seen: TaskGoal?)] = [:]
  private static let marker = Data("\"goal_status\"".utf8)

  static func read(_ url: URL, into goal: TaskGoal) -> TaskGoal {
    let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int).map(UInt64.init) ?? 0
    var (offset, seen) = cache[url.path] ?? (0, nil)
    if size < offset { (offset, seen) = (0, nil) }
    guard size > offset, let h = try? FileHandle(forReadingFrom: url) else { return seen ?? goal }
    defer { try? h.close() }
    try? h.seek(toOffset: offset)
    guard let data = try? h.readToEnd(), let end = data.lastIndex(of: 0x0A) else { return seen ?? goal }
    for line in data[..<end].split(separator: 0x0A) where line.range(of: marker) != nil {
      guard let row = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
        let status = row["attachment"] as? [String: Any], status["type"] as? String == "goal_status"
      else { continue }
      seen = next(seen ?? goal, status)
    }
    cache[url.path] = seen?.resolved == true ? nil : (offset + UInt64(data.distance(from: data.startIndex, to: end) + 1), seen)
    return seen ?? goal
  }

  private static func next(_ goal: TaskGoal, _ status: [String: Any]) -> TaskGoal {
    var g = goal
    if status["sentinel"] as? Bool == true {
      g.verdict = .working
      g.taken = 0
      g.reason = nil
      return g
    }
    let turns = status["iterations"] as? Int
    g.reason = status["reason"] as? String ?? g.reason
    if status["met"] as? Bool == true {
      g.verdict = .met
      g.taken = turns ?? g.taken + 1
    } else if status["failed"] as? Bool == true {
      g.verdict = .impossible
      g.taken = turns ?? g.taken + 1
    } else {
      g.verdict = .working
      g.taken += 1
    }
    return g
  }
}

extension Store {
  func goalProgress(_ t: BgTask) -> TaskGoal? {
    guard let goal = t.goal, !goal.resolved, let url = transcript(t) else { return t.goal }
    return GoalLog.read(url, into: goal)
  }

  func setGoal(_ task: String, done: String, turns: Int, key: String? = nil) {
    let stamp = DateFormatter()
    stamp.dateFormat = "yyyyMMdd-HHmm"
    let head = task.replacingOccurrences(of: "\n", with: " ").prefix(40)
    launch(
      task, name: "Goal: \(head)", loop: nil, in: paths.repo, worktree: "goal-\(stamp.string(from: Date()))", key: key,
      goal: TaskGoal(done: done, turns: turns))
  }
}
