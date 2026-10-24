import Foundation

struct Checks: Hashable {
  var passed = 0
  var failed = 0
  var pending = 0
  var failing: [String] = []
  var settled: Date?

  var total: Int { passed + failed + pending }
}

struct PullRequest: Decodable, Hashable, Identifiable {
  let number: Int
  let title: String
  let url: URL
  let state: String
  let isDraft: Bool
  let mergeable: String?
  let mergeStateStatus: String?
  let reviewDecision: String?
  let headRefName: String
  let headRefOid: String?
  let createdAt: Date?
  let updatedAt: Date?
  let mergedAt: Date?
  let closedAt: Date?
  let checks: Checks
  let door: String?
  let blast: String?
  let closes: [Int]

  var id: Int { number }
  var open: Bool { state == "OPEN" }
  var merged: Bool { state == "MERGED" }

  private struct Check: Decodable {
    let status: String?
    let conclusion: String?
    let state: String?
    let name: String?
    let context: String?
    let completedAt: String?
    let startedAt: String?
  }

  private enum Key: String, CodingKey {
    case number, title, url, state, isDraft, mergeable, mergeStateStatus, reviewDecision, headRefName, headRefOid
    case createdAt, updatedAt, mergedAt, closedAt, statusCheckRollup, body
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: Key.self)
    number = try c.decode(Int.self, forKey: .number)
    title = try c.decode(String.self, forKey: .title)
    url = try c.decode(URL.self, forKey: .url)
    state = (try? c.decode(String.self, forKey: .state)) ?? "OPEN"
    isDraft = (try? c.decode(Bool.self, forKey: .isDraft)) ?? false
    mergeable = try? c.decode(String.self, forKey: .mergeable)
    mergeStateStatus = try? c.decode(String.self, forKey: .mergeStateStatus)
    reviewDecision = (try? c.decode(String.self, forKey: .reviewDecision)).flatMap { $0.isEmpty ? nil : $0 }
    headRefName = (try? c.decode(String.self, forKey: .headRefName)) ?? ""
    headRefOid = try? c.decode(String.self, forKey: .headRefOid)
    createdAt = (try? c.decode(String.self, forKey: .createdAt)).flatMap(Reader.date)
    updatedAt = (try? c.decode(String.self, forKey: .updatedAt)).flatMap(Reader.date)
    mergedAt = (try? c.decode(String.self, forKey: .mergedAt)).flatMap(Reader.date)
    closedAt = (try? c.decode(String.self, forKey: .closedAt)).flatMap(Reader.date)
    var k = Checks()
    var finished: [Date] = []
    for x in (try? c.decode([Check].self, forKey: .statusCheckRollup)) ?? [] {
      if let d = (x.completedAt ?? x.startedAt).flatMap(Reader.date) { finished.append(d) }
      let v = (x.conclusion ?? x.state ?? "").uppercased()
      if ["FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "ERROR", "STARTUP_FAILURE"].contains(v) {
        k.failed += 1
        if let n = x.name ?? x.context { k.failing.append(n) }
      } else if v == "PENDING" || v == "EXPECTED" || (x.status.map { $0 != "COMPLETED" } ?? false) {
        k.pending += 1
      } else {
        k.passed += 1
      }
    }
    if k.pending == 0 { k.settled = finished.max() }
    checks = k
    let body = (try? c.decode(String.self, forKey: .body)) ?? ""
    door = Reader.groups(#"\*\*Door:\*\*\s*([A-Za-z-]+)"#, in: body).first?.lowercased()
    blast = Reader.groups(#"\*\*Blast Radius:\*\*\s*([^\n]+)"#, in: body).first?.trimmingCharacters(in: .whitespaces)
    let keyword = try! Regex(#"(?i)\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s+#(\d+)"#)
    closes = body.matches(of: keyword).compactMap { $0.output[1].substring.flatMap { Int($0) } }
  }

  var oneWay: Bool { door == "one-way" }

  var loop: String? {
    let parts = headRefName.split(separator: "/")
    guard parts.count >= 2, parts[0] == "loop" else { return nil }
    return "loop-\(parts[1])"
  }

  var issue: Int? {
    guard loop == "loop-issue-queue", let last = headRefName.split(separator: "/").last,
      let n = Int(last.prefix(while: \.isNumber)), n < 100_000
    else { return nil }
    return n
  }

  var issues: [Int] { closes + (issue.map { [$0] } ?? []) }

  var tidyTitle: String { tidy(title) }

  var blocker: String? {
    if !open { return merged ? "Already merged" : "Closed" }
    if isDraft { return "Draft" }
    if mergeable == "CONFLICTING" || mergeStateStatus == "DIRTY" { return "Has conflicts with main" }
    if checks.failed > 0 { return checks.failed == 1 ? "1 check failing" : "\(checks.failed) checks failing" }
    if checks.pending > 0 { return "Checks still running" }
    if mergeStateStatus == "BEHIND" { return "Behind main" }
    if mergeStateStatus == "BLOCKED" { return "Blocked by branch rules" }
    if reviewDecision == "CHANGES_REQUESTED" { return "Changes requested" }
    return nil
  }
}

struct Issue: Decodable, Hashable, Identifiable {
  let number: Int
  let title: String
  let url: URL
  let state: String
  let labels: [String]
  let assignees: [String]
  let createdAt: Date?
  let closedAt: Date?

  var id: Int { number }
  var open: Bool { state == "OPEN" }

  private struct Name: Decodable { let name: String?; let login: String? }

  private enum Key: String, CodingKey { case number, title, url, state, labels, assignees, createdAt, closedAt }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: Key.self)
    number = try c.decode(Int.self, forKey: .number)
    title = try c.decode(String.self, forKey: .title)
    url = try c.decode(URL.self, forKey: .url)
    state = (try? c.decode(String.self, forKey: .state)) ?? "OPEN"
    labels = ((try? c.decode([Name].self, forKey: .labels)) ?? []).compactMap(\.name)
    assignees = ((try? c.decode([Name].self, forKey: .assignees)) ?? []).compactMap(\.login)
    createdAt = (try? c.decode(String.self, forKey: .createdAt)).flatMap(Reader.date)
    closedAt = (try? c.decode(String.self, forKey: .closedAt)).flatMap(Reader.date)
  }
}

func tidy(_ title: String) -> String {
  var t = Substring(title)
  if let r = t.range(of: ": "), t[..<r.lowerBound].allSatisfy({ $0.isLetter || "()-_/".contains($0) }) {
    t = t[r.upperBound...]
  }
  return capitalizedFirst(String(t))
}

func capitalizedFirst(_ s: String) -> String {
  guard let first = s.first, first.isLowercase else { return s }
  let word = s.prefix { !$0.isWhitespace }
  if word.dropFirst().contains(where: { $0.isUppercase || "_./:".contains($0) }) { return s }
  return first.uppercased() + s.dropFirst()
}
