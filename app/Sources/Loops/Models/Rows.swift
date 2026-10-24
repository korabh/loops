import SwiftUI

enum LoopStatus: Equatable {
  case running(Date), starting, failed, due, outside(Int?), resting(Date?), off

  static func of(running: Date?, starting: Bool, paused: Bool, failed: Bool, standing: Standing, next: Date?, from: Int?) -> LoopStatus {
    if let running { return .running(running) }
    if starting { return .starting }
    if paused { return .off }
    if failed { return .failed }
    switch standing {
    case .due: return .due
    case .outside: return .outside(from)
    default: return .resting(next)
    }
  }

  var title: String {
    switch self {
    case .running: "Running"
    case .starting: "Starting"
    case .failed: "Last run failed"
    case .due: "Due"
    case .outside(let from): from.map { String(format: "After %02d:00", $0) } ?? "Outside its hours"
    case .resting: "Resting"
    case .off: "Off"
    }
  }

  var symbol: String {
    switch self {
    case .running, .starting: "waveform"
    case .failed: "xmark.circle"
    case .due: "clock"
    case .outside: "moon"
    case .resting: "checkmark.circle"
    case .off: "pause.circle"
    }
  }

  var tint: Color {
    switch self {
    case .running, .starting: .green
    case .failed: .red
    case .due: .orange
    default: .secondary
    }
  }

  var rank: Int {
    switch self {
    case .running: 0
    case .starting: 1
    case .failed: 2
    case .due: 3
    case .outside: 4
    case .resting: 5
    case .off: 6
    }
  }

  var active: Bool { rank < 2 }
}

struct InboxRow: Identifiable {
  enum Kind: Int, CaseIterable, Identifiable {
    case answer, merge, fix, decide, checks

    var id: Int { rawValue }

    var title: String {
      switch self {
      case .answer: "Answers"
      case .merge: "Ready to Merge"
      case .fix: "Needs Work"
      case .decide: "Decisions"
      case .checks: "Checks"
      }
    }

    var symbol: String {
      switch self {
      case .answer: "questionmark.bubble"
      case .merge: "arrow.trianglehead.merge"
      case .fix: "wrench.adjustable"
      case .decide: "text.bubble"
      case .checks: "exclamationmark.triangle"
      }
    }

    var tint: Color {
      switch self {
      case .answer, .decide: .orange
      case .merge: .green
      case .fix: .secondary
      case .checks: .red
      }
    }
  }

  enum Source {
    case task(BgTask)
    case item(Item)
    case problem(CIProblem)
  }

  let id: String
  let kind: Kind
  let title: String
  let detail: String
  let at: Date?
  var loop: String?
  var pr: Int?
  var oneWay = false
  let source: Source

  static func rows(
    answers: [InboxRow], items: [Item], waiting: [(pr: PullRequest, loop: String?, at: Date?)], problems: [InboxRow],
    state: (PullRequest) -> MergeState, loopTitle: (String) -> String
  ) -> [InboxRow] {
    var out = answers
    var seen = Set<Int>()
    for item in items {
      if let pr = item.pr {
        guard seen.insert(pr.number).inserted else { continue }
        let s = state(pr)
        out.append(
          InboxRow(
            id: item.id, kind: s.mergeable ? .merge : .fix, title: pr.tidyTitle,
            detail: [s.title, item.loops.first.map(loopTitle)].compactMap { $0 }.joined(separator: " · "), at: item.at,
            loop: item.loops.first, pr: pr.number, oneWay: pr.oneWay, source: .item(item)))
      } else {
        let rest = item.notes.first?.text
        out.append(
          InboxRow(
            id: item.id, kind: .decide, title: item.headline,
            detail: [item.loops.first.map(loopTitle), rest].compactMap { $0 }.joined(separator: " · "), at: item.at,
            loop: item.loops.first, source: .item(item)))
      }
    }
    for w in waiting where seen.insert(w.pr.number).inserted {
      let s = state(w.pr)
      guard s.mergeable || { if case .blocked = s { true } else { false } }() else { continue }
      let item = Item(id: "pr-\(w.pr.number)", kind: s.mergeable ? .merge : .review, pr: w.pr, asks: [])
      out.append(
        InboxRow(
          id: item.id, kind: s.mergeable ? .merge : .fix, title: w.pr.tidyTitle,
          detail: [s.title, w.loop.map(loopTitle)].compactMap { $0 }.joined(separator: " · "), at: w.at, loop: w.loop,
          pr: w.pr.number, oneWay: w.pr.oneWay, source: .item(item)))
    }
    out += problems
    return out.enumerated().sorted { a, b in
      let x = a.element
      let y = b.element
      if x.kind != y.kind { return x.kind.rawValue < y.kind.rawValue }
      if x.oneWay != y.oneWay { return x.oneWay }
      if x.at != y.at { return (x.at ?? .distantPast) > (y.at ?? .distantPast) }
      return a.offset < b.offset
    }.map(\.element)
  }
}

struct SpendDay: Identifiable, Equatable {
  let day: Date
  var cost = 0.0
  var tokens = 0
  var runs = 0

  var id: Date { day }

  static func days(_ runs: [RunStat], now: Date, count: Int = 7, calendar: Calendar = .current) -> [SpendDay] {
    let today = calendar.startOfDay(for: now)
    var out = (0..<count).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }.map { SpendDay(day: $0) }
    for r in runs {
      guard let i = out.firstIndex(where: { $0.day == calendar.startOfDay(for: r.at) }) else { continue }
      out[i].cost += r.tokens.cost
      out[i].tokens += r.tokens.total
      out[i].runs += 1
    }
    return out
  }
}

struct RunRow: Identifiable {
  let brief: Brief
  let run: RunStat?

  var id: Int { brief.id }

  static func rows(_ briefs: [Brief], runs: [RunStat]) -> [RunRow] {
    briefs.map { b in
      let near = runs.min { abs($0.end.timeIntervalSince(b.at)) < abs($1.end.timeIntervalSince(b.at)) }
      return RunRow(brief: b, run: near.flatMap { abs($0.end.timeIntervalSince(b.at)) < 1800 ? $0 : nil })
    }
  }

  var outcome: (title: String, symbol: String, tint: Color) {
    guard let run else { return ("Ran", "checkmark.circle", .secondary) }
    if run.limited { return ("Stopped at the limit", "hourglass", .orange) }
    if run.failed { return ("No result", "xmark.circle", .red) }
    return run.acted ? ("Did work", "checkmark.circle", .green) : ("Changed nothing", "minus.circle", .secondary)
  }
}

extension Stage {
  var tint: Color {
    switch self {
    case .ready: .green
    case .fixing: .orange
    case .done: .purple
    default: .secondary
    }
  }
}

extension TaskPhase {
  var title: String {
    switch self {
    case .limit: "Limit"
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

  var tint: Color {
    switch self {
    case .working: .green
    case .needsYou, .limit: .orange
    case .merge: .purple
    case .failed, .impossible: .red
    default: .secondary
    }
  }

  var rank: Int {
    switch self {
    case .needsYou: 0
    case .limit: 1
    case .working: 2
    case .merge: 3
    default: 4
    }
  }

  var open: Bool { rank < 4 }
}

extension Store {
  func loopStatus(_ l: LoopSpec) -> LoopStatus {
    let last = perf(l.name).runs.last
    return LoopStatus.of(
      running: running[l.name], starting: isStarting(l.name), paused: paused.contains(l.name),
      failed: last.map { $0.finished && $0.failed && !$0.limited } ?? false, standing: kind(l), next: nextRun[l.name], from: l.from)
  }

  func task(stable: String) -> BgTask? { tasks.first { $0.stable == stable } }

  var sidebarTasks: [BgTask] {
    let open = tasks.filter { phase($0).open }
    let recent = tasks.filter { !phase($0).open && now.timeIntervalSince($0.started) < 86400 }
    return Array((open + recent).prefix(8))
  }

  var inbox: [InboxRow] {
    let answers = needsInput.map { t in
      InboxRow(
        id: "task:\(t.stable)", kind: .answer, title: pendingInput(t)?.title ?? "It needs your answer", detail: Store.short(t),
        at: jobs.jobs[t.id]?.updated ?? t.started, loop: t.loop, source: .task(t))
    }
    let loopPRs = outcomes.filter { $0.kind == .pull && !$0.done && $0.actor == "You" }.compactMap { o in
      o.pr.map { (pr: $0, loop: Optional(o.loop), at: Optional(o.at)) }
    }
    let taskPRs = tasks.compactMap { t -> (pr: PullRequest, loop: String?, at: Date?)? in
      guard let pr = pull(of: t), pr.open else { return nil }
      return (pr, t.loop, pr.createdAt)
    }
    let problems = CI.shared.problems.map { p in
      InboxRow(id: "ci:\(p.id)", kind: .checks, title: p.title, detail: p.detail, at: p.at, source: .problem(p))
    }
    return InboxRow.rows(
      answers: answers, items: items, waiting: loopPRs + taskPRs, problems: problems, state: mergeState, loopTitle: title)
  }

  static func headline(_ t: BgTask) -> String {
    let line = t.prompt.split(separator: "\n").first.map(String.init) ?? short(t)
    return line.count > 120 ? String(line.prefix(117)) + "…" : line
  }

  static func short(_ t: BgTask) -> String {
    guard let i = t.title.range(of: ": ") else { return t.title }
    return String(t.title[i.upperBound...])
  }

  func pullURL(_ n: Int) -> URL? {
    if let url = pulls[n]?.url { return url }
    return pulls.values.first.map { $0.url.deletingLastPathComponent().appending(path: String(n)) }
  }

  func liveStep(_ loop: String) -> String? {
    guard let agents = live?.agents(for: loop), !agents.isEmpty else { return nil }
    let active = agents.filter { !$0.finished && !$0.stalled }
    return (active.last ?? agents.last)?.current
  }
}

extension Briefs {
  static func first(_ b: Brief) -> String {
    let body = body(b)
    return capitalizedFirst(readable(sentences(body).first ?? body))
  }
}
