import Foundation
import Testing

@testable import Loops

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func iso(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }

private func pull(
  _ number: Int, state: String = "OPEN", branch: String = "loop/pr-fix/x", created: Date = now.addingTimeInterval(-86400 * 3),
  updated: Date? = nil, merged: Date? = nil, checks: [(String, Date?)] = [("SUCCESS", nil)]
) -> PullRequest {
  let rollup = checks.map { c in
    let done = c.1.map { #","completedAt":"\#(iso($0))""# } ?? ""
    return #"{"conclusion":"\#(c.0)","status":"\#(c.0 == "PENDING" ? "IN_PROGRESS" : "COMPLETED")","name":"check"\#(done)}"#
  }.joined(separator: ",")
  let json = """
    {"number":\(number),"title":"fix: thing \(number)","url":"https://github.com/o/r/pull/\(number)","state":"\(state)",
    "isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefName":"\(branch)","headRefOid":"abc",
    "createdAt":"\(iso(created))"\(updated.map { #","updatedAt":"\#(iso($0))""# } ?? "")\(merged.map { #","mergedAt":"\#(iso($0))""# } ?? ""),
    "statusCheckRollup":[\(rollup)],"body":""}
    """
  return try! JSONDecoder().decode(PullRequest.self, from: Data(json.utf8))
}

private func ask(_ text: String, loop: String = "loop-pr-review", at: Date) -> Ask {
  Ask(id: "\(loop)|\(text)", loop: loop, text: text, url: nil, at: at)
}

private func prRow(_ pr: PullRequest, kind: InboxRow.Kind = .merge, asks: [Ask] = [], at: Date? = nil) -> InboxRow {
  InboxRow(
    id: "pr-\(pr.number)", kind: kind, title: pr.tidyTitle, detail: "", at: at ?? pr.createdAt, pr: pr.number,
    source: .item(Item(id: "pr-\(pr.number)", kind: kind == .merge ? .merge : .review, pr: pr, asks: asks)))
}

private func decision(_ id: String, _ title: String, at: Date) -> InboxRow {
  let a = ask(title, loop: "loop-tests", at: at)
  return InboxRow(id: id, kind: .decide, title: title, detail: "", at: at, source: .item(Item(id: id, kind: .decide, pr: nil, asks: [a])))
}

private func task(_ id: String) -> InboxRow {
  let t = BgTask(id: id, title: "Task: which?", loop: nil, prompt: "p", started: now)
  return InboxRow(id: "task:\(id)", kind: .answer, title: "Which?", detail: "", at: now, source: .task(t))
}

private func problem(_ id: String) -> InboxRow {
  let p = CIProblem(id: id, kind: .billing, title: "Billing", detail: "", at: now, action: nil)
  return InboxRow(id: "ci:\(id)", kind: .checks, title: "Billing", detail: "", at: now, source: .problem(p))
}

@Suite struct Holders {
  @Test func everyInboxKindHasAHolder() {
    #expect(Holder.of(.merge) == .merge)
    #expect(Holder.of(.fix) == .fix)
    #expect(Holder.of(.answer) == .decide)
    #expect(Holder.of(.decide) == .decide)
    #expect(Holder.of(.checks) == .checks)
  }

  @Test func mergedCountsLoopPullRequestsFromTheLastSevenDays() {
    let pulls = [
      pull(10, state: "MERGED", merged: now.addingTimeInterval(-86400)),
      pull(11, state: "MERGED", merged: now.addingTimeInterval(-6 * 86400)),
      pull(12, state: "MERGED", merged: now.addingTimeInterval(-8 * 86400)),
      pull(13, state: "MERGED", branch: "feat/mine", merged: now.addingTimeInterval(-3600)),
      pull(14, state: "CLOSED"),
    ]
    #expect(Attention.merged(pulls, now: now) == 2)
  }
}

@Suite struct Sentences {
  @Test func nothingWaitingSaysWhatTheLoopsHold() {
    #expect(Attention.sentence(counts: [:], loops: 3, oldest: nil) == "Nothing needs you. Loops are working on 3 pull requests.")
    #expect(Attention.sentence(counts: [:], loops: 1, oldest: nil) == "Nothing needs you. Loops are working on 1 pull request.")
    #expect(Attention.sentence(counts: [:], loops: 0, oldest: nil) == "All clear.")
  }

  @Test func oneKindReadsAsOneClause() {
    #expect(Attention.sentence(counts: [.merge: 1], loops: 0, oldest: nil) == "1 pull request can merge.")
    #expect(Attention.sentence(counts: [.fix: 3], loops: 2, oldest: nil) == "3 pull requests need a fix.")
    #expect(Attention.sentence(counts: [.decide: 1], loops: 0, oldest: nil) == "1 decision is open.")
    #expect(Attention.sentence(counts: [.checks: 2], loops: 0, oldest: nil) == "CI has 2 problems.")
  }

  @Test func severalKindsShareOneSeriesAndNamePullRequestsOnce() {
    let counts: [InboxRow.Kind: Int] = [.merge: 2, .fix: 3, .decide: 11]
    #expect(
      Attention.sentence(counts: counts, loops: 0, oldest: ("Infra red", 13 * 86400))
        == "2 pull requests can merge, 3 need a fix, and 11 decisions are open. The oldest, \u{201C}Infra red\u{201D}, has waited 13 days.")
    #expect(Attention.sentence(counts: [.fix: 1, .answer: 1], loops: 0, oldest: nil) == "1 pull request needs a fix and 1 task needs your answer.")
    #expect(Attention.sentence(counts: [.merge: 1, .fix: 1], loops: 0, oldest: ("A", 3600)) == "1 pull request can merge and 1 needs a fix. The oldest, \u{201C}A\u{201D}, has waited 1 hour.")
  }

  @Test func durationsReadInWords() {
    #expect(Attention.duration(20) == "1 minute")
    #expect(Attention.duration(25 * 60) == "25 minutes")
    #expect(Attention.duration(30 * 3600) == "30 hours")
    #expect(Attention.duration(50 * 3600) == "2 days")
  }
}

@Suite struct Timelines {
  @Test func rowsAreTheOldestSixColouredByWhoActs() {
    let rows = [prRow(pull(1), at: now.addingTimeInterval(-3600)), problem("billing")]
      + (0..<6).map { i in decision("d\(i)", "Decision \(i)", at: now.addingTimeInterval(-Double(i + 2) * 3600)) }
    let waits = Wait.longest(rows, since: \.at, now: now)
    #expect(waits.map(\.id) == ["d5", "d4", "d3", "d2", "d1", "d0"])
    #expect(waits.allSatisfy { $0.holder == .decide })
    let recent = Wait.longest(Array(rows.prefix(2)), since: \.at, now: now)
    #expect(recent.map(\.holder) == [.merge, .checks])
    #expect(recent.first?.title == "#1 Thing 1")
    #expect(recent.first?.age == "1h")
  }

}

@Suite struct Waits {
  @Test func agesReadInHoursThenDays() {
    #expect(Clock.short(6 * 3600) == "6h")
    #expect(Clock.short(30 * 3600) == "30h")
    #expect(Clock.short(50 * 3600) == "2d")
    #expect(Clock.short(25 * 60) == "25m")
  }

  @Test func oldestComesFirstAndTheListStopsAtItsLimit() {
    let rows = (0..<8).map { i in decision("d\(i)", "Decision \(i)", at: now.addingTimeInterval(-Double(i) * 3600)) }
    let waits = Wait.longest(rows, since: \.at, now: now, limit: 6)
    #expect(waits.map(\.id) == ["d7", "d6", "d5", "d4", "d3", "d2"])
    #expect(waits.first?.age == "7h")
  }

  @Test func rowsWithNoTimeAreLeftOut() {
    let problem = CIProblem(id: "runners", kind: .runners, title: "2 runners offline", detail: "", at: nil, action: nil)
    let rows = [InboxRow(id: "ci:runners", kind: .checks, title: problem.title, detail: "", at: nil, source: .problem(problem))]
    #expect(Wait.longest(rows, since: { Wait.since($0, reviewed: [:], asked: [:]) }, now: now).isEmpty)
  }

  @Test func anAskedItemWaitsSinceItWasFirstAsked() {
    let a = ask("Pick a name", loop: "loop-tests", at: now.addingTimeInterval(-3600))
    let row = InboxRow(id: "d", kind: .decide, title: "Pick a name", detail: "", at: a.at, source: .item(Item(id: "d", kind: .decide, pr: nil, asks: [a])))
    #expect(Wait.since(row, reviewed: [:], asked: [:]) == a.at)
    #expect(Wait.since(row, reviewed: [:], asked: [a.id: now.addingTimeInterval(-86400)]) == now.addingTimeInterval(-86400))
  }

  @Test func aReadyPullRequestWaitsSinceItsLastReviewOrGreenCheck() {
    let green = now.addingTimeInterval(-5 * 3600)
    let pr = pull(7, updated: now.addingTimeInterval(-600), checks: [("SUCCESS", green), ("SUCCESS", green.addingTimeInterval(-60))])
    let row = prRow(pr)
    #expect(pr.checks.settled == green)
    #expect(Wait.since(row, reviewed: [:], asked: [:]) == green)
    #expect(Wait.since(row, reviewed: [7: now.addingTimeInterval(-3600)], asked: [:]) == now.addingTimeInterval(-3600))
    #expect(Wait.since(prRow(pull(8, updated: now.addingTimeInterval(-600))), reviewed: [:], asked: [:]) == now.addingTimeInterval(-600))
  }

  @Test func runningChecksHaveNotSettled() {
    #expect(pull(9, checks: [("SUCCESS", now), ("PENDING", nil)]).checks.settled == nil)
  }

  @Test func answersAndProblemsUseTheirOwnTimes() {
    let task = BgTask(id: "t", title: "T", loop: nil, prompt: "p", started: now.addingTimeInterval(-7200))
    let answer = InboxRow(id: "task:t", kind: .answer, title: "Which?", detail: "", at: now.addingTimeInterval(-60), source: .task(task))
    let p = CIProblem(id: "billing", kind: .billing, title: "Billing", detail: "", at: now.addingTimeInterval(-99), action: nil)
    let problem = InboxRow(id: "ci:billing", kind: .checks, title: "Billing", detail: "", at: nil, source: .problem(p))
    #expect(Wait.since(answer, reviewed: [:], asked: [:]) == now.addingTimeInterval(-60))
    #expect(Wait.since(problem, reviewed: [:], asked: [:]) == now.addingTimeInterval(-99))
  }

  @Test func namesAreShortTitlesWithoutLoopPrefixes() {
    #expect(Wait.name("Infra red: since 00:09Z every Check job fails in 3s") == "Infra red")
    #expect(Wait.name("dep-drift: 50 bun audit advisories; none can be fixed") == "50 bun audit advisories")
    #expect(Wait.name("decide: file #186 Out of scope as follow-ups?") == "File #186 Out of scope as…")
    #expect(Wait.name("component-factory: survey workflow errored (\"Cannot access\")") == "Survey workflow errored")
    #expect(Wait.name("Merge each PR as it lands to release the next.") == "Merge each PR as it lands…")
    #expect(Wait.name("Zod 4") == "Zod 4")
  }

  @Test func longTitlesAreCutAtAWord() {
    #expect(Wait.short("Should `loop-tests` run every hour instead of every four hours?") == "Should loop-tests run…")
    #expect(Wait.short("**Rename** it") == "Rename it")
  }

  @Test func reviewTimesComeFromTheLatestReviewerBrief() {
    let briefs = [
      Brief(id: 0, at: now.addingTimeInterval(-7200), loop: "loop-pr-review", text: "#7 merge after 1 fix\n#8 merge"),
      Brief(id: 1, at: now.addingTimeInterval(-3600), loop: "loop-pr-review", text: "#7 merge"),
      Brief(id: 2, at: now, loop: "loop-tests", text: "#8 is mentioned elsewhere"),
    ]
    #expect(Wait.reviewed(briefs) == [7: now.addingTimeInterval(-3600), 8: now.addingTimeInterval(-7200)])
  }

  @Test func anAskRepeatedInBackToBackBriefsWaitsSinceTheFirst() {
    let line = "Needs a person: pick a name for the thing"
    let briefs = [
      Brief(id: 0, at: now.addingTimeInterval(-4 * 3600), loop: "loop-tests", text: line),
      Brief(id: 1, at: now.addingTimeInterval(-3 * 3600), loop: "loop-tests", text: "Nothing to ask."),
      Brief(id: 2, at: now.addingTimeInterval(-2 * 3600), loop: "loop-tests", text: line),
      Brief(id: 3, at: now.addingTimeInterval(-3600), loop: "loop-tests", text: "Did a thing.\n\(line)"),
      Brief(id: 4, at: now, loop: "loop-perf", text: line),
    ]
    let asks = Briefs.asks(briefs[3])
    #expect(asks.count == 1)
    #expect(Wait.asked(asks, briefs: briefs) == [asks[0].id: now.addingTimeInterval(-2 * 3600)])
  }
}
