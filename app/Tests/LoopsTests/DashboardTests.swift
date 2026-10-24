import Foundation
import Testing

@testable import Loops

private let start = Date(timeIntervalSince1970: 1_800_000_000)

private func run(_ id: String, at: Date, endsAfter hours: Double = 0.5, cost: Double, tokens: Int) -> RunStat {
  var r = RunStat(id: id, loop: "loop-tests", at: at, end: at.addingTimeInterval(hours * 3600))
  r.main = Tokens(input: tokens, cost: cost)
  return r
}

private func pull(
  _ number: Int, state: String = "OPEN", draft: Bool = false, mergeable: String = "MERGEABLE", status: String = "CLEAN",
  head: String = "abc", checks: [String] = ["SUCCESS"], branch: String = "loop/pr-fix/x", body: String = ""
) -> PullRequest {
  let rollup = checks.map { #"{"conclusion":"\#($0)","status":"COMPLETED","name":"check"}"# }.joined(separator: ",")
  let json = """
    {"number":\(number),"title":"fix: thing \(number)","url":"https://github.com/o/r/pull/\(number)","state":"\(state)","isDraft":\(draft),
    "mergeable":"\(mergeable)","mergeStateStatus":"\(status)","headRefName":"\(branch)","headRefOid":"\(head)",
    "createdAt":"2027-01-15T08:00:00Z","statusCheckRollup":[\(rollup)],"body":\(String(reflecting: body))}
    """
  return try! JSONDecoder().decode(PullRequest.self, from: Data(json.utf8))
}

@Suite struct SpendDays {
  @Test func eachRunLandsOnItsDay() {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let now = start
    let days = SpendDay.days(
      [
        run("a", at: now.addingTimeInterval(-3600), cost: 2, tokens: 200), run("b", at: now.addingTimeInterval(-86400), cost: 1, tokens: 100),
        run("old", at: now.addingTimeInterval(-30 * 86400), cost: 9, tokens: 900),
      ], now: now, calendar: cal)
    #expect(days.count == 7)
    #expect(days.last?.cost == 2)
    #expect(days.last?.runs == 1)
    #expect(days[5].tokens == 100)
    #expect(days.map(\.cost).reduce(0, +) == 3)
  }

  @Test func noRunsIsSevenEmptyDays() {
    let days = SpendDay.days([], now: start)
    #expect(days.count == 7)
    #expect(days.allSatisfy { $0.cost == 0 && $0.runs == 0 })
  }
}

@Suite struct Pages {
  @Test(arguments: Page.top) func topPagesRoundTrip(page: Page) {
    #expect(Page(id: page.id) == page)
  }

  @Test func loopsAndTasksRoundTrip() {
    #expect(Page(id: Page.loop("loop-tests").id) == .loop("loop-tests"))
    #expect(Page(id: Page.task("abc123").id) == .task("abc123"))
  }

  @Test func oldPageNamesStillOpen() {
    #expect(Page(id: "overview") == .home)
    #expect(Page(id: "waiting") == .inbox)
    #expect(Page(id: "results") == .pulls)
    #expect(Page(id: "ci") == .checks)
    #expect(Page(id: "goals") == .tasks)
    #expect(Page(id: "nonsense") == nil)
  }
}

@Suite struct Merging {
  @Test func readyOnlyOnceReviewedAtItsHeadWithNothingBlocking() {
    #expect(MergeState.of(pull(1), reviewed: "abc", verdict: "merge") == .ready)
    #expect(MergeState.of(pull(1), reviewed: "abc", verdict: nil).mergeable)
  }

  @Test func eachBlockerWinsInOrder() {
    #expect(MergeState.of(pull(1, state: "MERGED"), reviewed: nil, verdict: nil) == .merged)
    #expect(MergeState.of(pull(1, state: "CLOSED"), reviewed: nil, verdict: nil) == .closed)
    #expect(MergeState.of(pull(1, draft: true), reviewed: "abc", verdict: nil) == .draft)
    #expect(MergeState.of(pull(1, checks: ["FAILURE", "SUCCESS"]), reviewed: "abc", verdict: nil) == .failing(1))
    #expect(MergeState.of(pull(1, checks: ["PENDING"]), reviewed: "abc", verdict: nil) == .checking)
    #expect(MergeState.of(pull(1, mergeable: "CONFLICTING"), reviewed: "abc", verdict: nil) == .conflicting)
    #expect(MergeState.of(pull(1), reviewed: nil, verdict: nil) == .unreviewed)
    #expect(MergeState.of(pull(1), reviewed: "old", verdict: nil) == .rereview)
    #expect(MergeState.of(pull(1), reviewed: "abc", verdict: "merge after 2 fixes") == .fixes(2))
    #expect(MergeState.of(pull(1), reviewed: "abc", verdict: "merge after act on") == .fixes(nil))
    #expect(MergeState.of(pull(1, status: "BEHIND"), reviewed: "abc", verdict: nil) == .behind)
    #expect(MergeState.of(pull(1, status: "BLOCKED"), reviewed: "abc", verdict: nil) == .blocked("Blocked by branch rules"))
  }

  @Test func stagesFollowTheState() {
    #expect(MergeState.ready.stage == .ready)
    #expect(MergeState.blocked("x").stage == .ready)
    #expect(MergeState.unreviewed.stage == .review)
    #expect(MergeState.failing(2).stage == .fixing)
    #expect(MergeState.draft.stage == .building)
    #expect(!MergeState.blocked("x").mergeable)
  }
}

@Suite struct LoopStatuses {
  @Test func runningBeatsEverything() {
    let s = LoopStatus.of(running: start, starting: true, paused: true, failed: true, standing: .due, next: nil, from: nil)
    #expect(s == .running(start))
    #expect(s.active)
  }

  @Test func offBeatsFailedAndDue() {
    #expect(LoopStatus.of(running: nil, starting: false, paused: true, failed: true, standing: .due, next: nil, from: nil) == .off)
    #expect(LoopStatus.of(running: nil, starting: false, paused: false, failed: true, standing: .due, next: nil, from: nil) == .failed)
    #expect(LoopStatus.of(running: nil, starting: false, paused: false, failed: false, standing: .outside, next: nil, from: 8) == .outside(8))
    #expect(LoopStatus.of(running: nil, starting: false, paused: false, failed: false, standing: .resting, next: start, from: nil) == .resting(start))
  }

  @Test func ranksSortActiveFirst() {
    let order: [LoopStatus] = [.off, .resting(nil), .outside(nil), .due, .failed, .starting, .running(start)]
    #expect(order.sorted { $0.rank < $1.rank } == order.reversed())
  }
}

@Suite struct Inbox {
  private func ask(_ text: String, at: TimeInterval) -> Ask {
    Ask(id: text, loop: "loop-pr-review", text: text, url: nil, at: start.addingTimeInterval(at))
  }

  @Test func aPullRequestShowsOnceAndAnswersComeFirst() {
    let pr = pull(7)
    let item = Item(id: "pr-7", kind: .merge, pr: pr, asks: [ask("#7 ready", at: 0)])
    let decide = Item(id: "d", kind: .decide, pr: nil, asks: [ask("Pick a name", at: 60)])
    let answer = InboxRow(
      id: "task:x", kind: .answer, title: "Which?", detail: "", at: start, source: .item(decide))
    let rows = InboxRow.rows(
      answers: [answer], items: [item, decide], waiting: [(pr, "loop-pr-fix", start)], problems: [], state: { _ in .ready },
      loopTitle: { $0 })
    #expect(rows.map(\.id) == ["task:x", "pr-7", "d"])
    #expect(rows.map(\.kind) == [.answer, .merge, .decide])
  }

  @Test func onlyReadyOrBlockedWaitingPullRequestsJoin() {
    let rows = InboxRow.rows(
      answers: [], items: [], waiting: [(pull(1), nil, start), (pull(2), nil, start), (pull(3), nil, start)], problems: [],
      state: { $0.number == 1 ? .ready : $0.number == 2 ? .blocked("Changes requested") : .unreviewed }, loopTitle: { $0 })
    #expect(rows.map(\.pr) == [1, 2])
    #expect(rows.map(\.kind) == [.merge, .fix])
  }

  @Test func oneWayDoorsLeadTheirGroup() {
    let safe = pull(1)
    let risky = pull(2, body: "**Door:** one-way")
    let rows = InboxRow.rows(
      answers: [], items: [], waiting: [(safe, nil, start.addingTimeInterval(100)), (risky, nil, start)], problems: [],
      state: { _ in .ready }, loopTitle: { $0 })
    #expect(rows.map(\.pr) == [2, 1])
  }
}

@Suite struct Runs {
  @Test func aBriefMatchesTheRunThatEndedWithinHalfAnHour() {
    let near = run("near", at: start.addingTimeInterval(-600), endsAfter: 0.1, cost: 1, tokens: 10)
    let far = run("far", at: start.addingTimeInterval(-7200), endsAfter: 0.1, cost: 1, tokens: 10)
    let rows = RunRow.rows(
      [Brief(id: 1, at: start, loop: "loop-tests", text: "did it"), Brief(id: 2, at: start.addingTimeInterval(-86400), loop: "loop-tests", text: "x")],
      runs: [near, far])
    #expect(rows.first?.run?.id == "near")
    #expect(rows.last?.run == nil)
  }
}

@Suite struct Resuming {
  @Test func aResumedTaskKeepsItsStableID() {
    let t = BgTask(id: "first", title: "T", loop: nil, prompt: "p", started: start)
    let again = t.resumed(as: "second", resumes: 1)
    #expect(again.id == "second")
    #expect(again.stable == "first")
    #expect(again.resumed(as: "third", resumes: 2).stable == "first")
  }
}

@Suite struct AppIcons {
  static let loops = [
    "loop-green-main", "loop-prod-errors", "loop-issue-queue", "loop-pr-review", "loop-pr-fix", "loop-convex-review",
    "loop-tests", "loop-dep-drift", "loop-convex-cost", "loop-correct", "loop-parked-branches", "loop-unknown",
  ]

  @Test(arguments: loops) func everyLoopHasAPhosphorIcon(loop: String) {
    #expect(PhosphorData.paths[Icons.resolve(Symbols.loop(loop))] != nil)
  }

  @Test func everyPageAndStatusHasAPhosphorIcon() {
    let statuses: [LoopStatus] = [.running(start), .starting, .failed, .due, .outside(nil), .resting(nil), .off]
    let names =
      Page.top.map(\.symbol) + statuses.map(\.symbol) + InboxRow.Kind.allCases.map(\.symbol) + Stage.allCases.map(\.symbol)
      + [Symbols.openOnGitHub, Symbols.askClaude, Symbols.goal, Symbols.more, Symbols.billing]
    for name in names {
      #expect(PhosphorData.paths[Icons.resolve(name)] != nil, "\(name)")
    }
  }

  @Test func everyMappedIconIsBundled() {
    let missing = Set(Icons.names.values).filter { PhosphorData.paths[$0] == nil }
    #expect(missing.isEmpty, "\(missing.sorted())")
  }
}

@Suite struct TableSizes {
  @Test func biggerAndSmallerStopAtTheEnds() {
    #expect(RowSize.small.bigger == .medium)
    #expect(RowSize.medium.bigger == .large)
    #expect(RowSize.large.bigger == .large)
    #expect(RowSize.large.smaller == .medium)
    #expect(RowSize.small.smaller == .small)
  }

  @Test func rowsGrowWithTheirSize() {
    let heights = RowSize.allCases.map(\.height)
    #expect(heights == heights.sorted())
    #expect(Set(heights).count == heights.count)
  }
}
