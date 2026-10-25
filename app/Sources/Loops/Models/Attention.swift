import Foundation
import SwiftUI

enum Holder: Int, CaseIterable, Identifiable {
  case merge, fix, decide, checks, loops

  var id: Int { rawValue }

  static func of(_ kind: InboxRow.Kind) -> Holder {
    switch kind {
    case .merge: .merge
    case .fix: .fix
    case .answer, .decide: .decide
    case .checks: .checks
    }
  }

  var title: String {
    switch self {
    case .merge: "Merge"
    case .fix: "Fix"
    case .decide: "Decide"
    case .checks: "Checks"
    case .loops: "Loops on it"
    }
  }

  var tint: Color {
    switch self {
    case .merge: .green
    case .fix, .decide: .orange
    case .checks: .red
    case .loops: .secondary
    }
  }

  var hint: String {
    switch self {
    case .merge: "Ready for you to merge"
    case .fix: "Pull requests that need a fix before they can merge"
    case .decide: "Decisions and answers the loops asked you for"
    case .checks: "CI setup problems: billing, runners or stuck runs"
    case .loops: "Open loop pull requests a loop is checking, reviewing or fixing"
    }
  }
}

struct Share: Identifiable, Equatable {
  let holder: Holder
  var count = 0
  var first: String?

  var id: Int { holder.rawValue }
}

enum Attention {
  static func shares(inbox: [InboxRow], pulls: [PullRequest]) -> [Share] {
    var out = Holder.allCases.map { Share(holder: $0) }
    for row in inbox {
      let i = Holder.of(row.kind).rawValue
      out[i].count += 1
      if out[i].first == nil { out[i].first = row.id }
    }
    let held = Set(inbox.compactMap(\.pr))
    out[Holder.loops.rawValue].count = Set(pulls.filter { $0.open && $0.loop != nil && !held.contains($0.number) }.map(\.number)).count
    return out
  }

  static func merged(_ pulls: [PullRequest], now: Date) -> Int {
    let week = now.addingTimeInterval(-7 * 86400)
    return pulls.filter { pr in pr.merged && pr.loop != nil && pr.mergedAt.map { $0 >= week && $0 <= now } ?? false }.count
  }

  static func counts(_ inbox: [InboxRow]) -> [InboxRow.Kind: Int] {
    inbox.reduce(into: [:]) { $0[$1.kind, default: 0] += 1 }
  }

  static func sentence(counts: [InboxRow.Kind: Int], loops: Int, oldest: (name: String, seconds: TimeInterval)?) -> String {
    var parts: [String] = []
    var named = false
    func pulls(_ n: Int) -> String {
      defer { named = true }
      return named ? "\(n)" : n == 1 ? "1 pull request" : "\(n) pull requests"
    }
    if let n = counts[.merge], n > 0 { parts.append("\(pulls(n)) can merge") }
    if let n = counts[.fix], n > 0 { parts.append("\(pulls(n)) \(n == 1 ? "needs" : "need") a fix") }
    if let n = counts[.answer], n > 0 { parts.append(n == 1 ? "1 task needs your answer" : "\(n) tasks need your answer") }
    if let n = counts[.decide], n > 0 { parts.append(n == 1 ? "1 decision is open" : "\(n) decisions are open") }
    if let n = counts[.checks], n > 0 { parts.append(n == 1 ? "CI has 1 problem" : "CI has \(n) problems") }
    guard !parts.isEmpty else {
      return loops > 0 ? "Nothing needs you. Loops are working on \(loops == 1 ? "1 pull request" : "\(loops) pull requests")." : "All clear."
    }
    let first = capitalizedFirst(series(parts)) + "."
    guard let oldest else { return first }
    return "\(first) The oldest, \u{201C}\(oldest.name)\u{201D}, has waited \(duration(oldest.seconds))."
  }

  static func series(_ parts: [String]) -> String {
    switch parts.count {
    case 0: ""
    case 1: parts[0]
    case 2: "\(parts[0]) and \(parts[1])"
    default: parts.dropLast().joined(separator: ", ") + ", and " + parts[parts.count - 1]
    }
  }

  static func duration(_ seconds: TimeInterval) -> String {
    let m = Int(max(0, seconds) / 60)
    if m < 60 { return plural(max(m, 1), "minute") }
    if m < 48 * 60 { return plural(Int((Double(m) / 60).rounded()), "hour") }
    return plural(Int((Double(m) / 1440).rounded()), "day")
  }

}

struct Wait: Identifiable, Equatable {
  let id: String
  let name: String
  let title: String
  let holder: Holder
  let since: Date
  let seconds: TimeInterval

  var age: String { Clock.short(seconds) }

  static func since(_ row: InboxRow, reviewed: [Int: Date], asked: [String: Date]) -> Date? {
    switch row.source {
    case .task: return row.at
    case .problem(let p): return p.at
    case .item(let item):
      if !item.asks.isEmpty { return item.asks.map { asked[$0.id] ?? $0.at }.min() }
      guard let pr = item.pr else { return row.at }
      return [reviewed[pr.number], pr.checks.settled].compactMap { $0 }.max() ?? pr.updatedAt ?? pr.createdAt ?? row.at
    }
  }

  static func plain(_ text: String) -> String {
    text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func short(_ text: String, limit: Int = 26) -> String {
    let plain = plain(text)
    guard plain.count > limit else { return plain }
    let cut = plain.prefix(limit - 1)
    let word = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
    return word.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters)) + "…"
  }

  static func name(_ text: String, limit: Int = 28) -> String {
    var t = plain(text)
    if let r = t.range(of: ": ") {
      let head = String(t[..<r.lowerBound])
      if head.range(of: #"^[a-z][a-z0-9-]*$"#, options: .regularExpression) != nil {
        t = String(t[r.upperBound...])
      } else if head.count >= 3, head.count <= limit, !head.contains("#") {
        return capitalizedFirst(head)
      }
    }
    let stops = [" (", "; ", " — ", ". "].compactMap { t.range(of: $0)?.lowerBound }
      .filter { t.distance(from: t.startIndex, to: $0) >= 8 }
    if let cut = stops.min() { t = String(t[..<cut]) }
    return short(capitalizedFirst(t.trimmingCharacters(in: CharacterSet(charactersIn: ". "))), limit: limit)
  }

  static func longest(_ rows: [InboxRow], since: (InboxRow) -> Date?, now: Date, limit: Int = 6) -> [Wait] {
    var waits: [(order: Int, wait: Wait)] = []
    for (i, row) in rows.enumerated() {
      guard let at = since(row) else { continue }
      let title = row.pr.map { "#\($0) \(plain(row.title))" } ?? plain(row.title)
      let wait = Wait(
        id: row.id, name: name(row.title), title: title, holder: Holder.of(row.kind), since: at,
        seconds: max(0, now.timeIntervalSince(at)))
      waits.append((i, wait))
    }
    let sorted = waits.sorted { a, b in a.wait.since != b.wait.since ? a.wait.since < b.wait.since : a.order < b.order }
    return sorted.prefix(limit).map(\.wait)
  }

  static func reviewed(_ briefs: [Brief]) -> [Int: Date] {
    var out: [Int: Date] = [:]
    for b in briefs where b.loop == "loop-pr-review" {
      for line in b.text.split(separator: "\n") where line.hasPrefix("#") {
        guard let n = Reader.groups(#"^#(\d+) "#, in: line).first.flatMap(Int.init) else { continue }
        out[n] = max(out[n] ?? b.at, b.at)
      }
    }
    return out
  }

  static func asked(_ asks: [Ask], briefs: [Brief]) -> [String: Date] {
    let byLoop = Dictionary(grouping: briefs, by: \.loop).mapValues { $0.sorted { $0.at > $1.at } }
    var parsed: [Int: Set<String>] = [:]
    var out: [String: Date] = [:]
    for a in asks {
      var first = a.at
      for b in byLoop[a.loop] ?? [] where b.at <= a.at {
        let ids = parsed[b.id] ?? Set(Briefs.asks(b).map(\.id))
        parsed[b.id] = ids
        guard ids.contains(a.id) else { break }
        first = b.at
      }
      out[a.id] = first
    }
    return out
  }
}

extension Store {
  func waits(_ inbox: [InboxRow], limit: Int = 6) -> [Wait] {
    Wait.longest(inbox, since: { Wait.since($0, reviewed: reviewedAt, asked: askedAt) }, now: now, limit: limit)
  }
}
