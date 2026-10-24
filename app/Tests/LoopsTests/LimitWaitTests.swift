import Foundation
import Testing

@testable import Loops

private let paris = TimeZone(identifier: "Europe/Paris")!

private func at(_ text: String) -> Date {
  let f = ISO8601DateFormatter()
  return f.date(from: text)!
}

@MainActor
struct LimitWait {
  let now = at("2026-10-17T07:40:00Z")

  @Test func aSessionLimitWaitsUntilItsReset() {
    let hit = Planner.paused(
      ["is_error": true, "result": "You've hit your session limit · resets 4:50pm (Europe/Paris)"], out: "", now: now)
    #expect(hit?.limit == "You've hit your session limit · resets 4:50pm (Europe/Paris)")
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = paris
    #expect(hit.map { cal.component(.hour, from: $0.until) } == 16)
    #expect(hit.map { $0.until > now } == true)
  }

  @Test func aModelCapWithNoResetTimeWaitsAnHour() {
    let hit = Planner.paused(
      ["is_error": true, "result": "You've reached your Fable limit. Switch to another model, or manage usage credits."], out: "", now: now)
    #expect(hit?.until == now.addingTimeInterval(3600))
    #expect(hit?.limit.hasPrefix("You've reached your Fable limit") == true)
  }

  @Test func aLimitPrintedWithoutJSONStillWaits() {
    let hit = Planner.paused(nil, out: "Error: You've hit your weekly limit · resets Oct 18 at 6am (Europe/Paris)", now: now)
    #expect(hit?.until == at("2026-10-18T04:00:00Z"))
  }

  @Test func anAnswerThatQuotesALimitIsNotOne() {
    let result = "Q7: 'You've reached your day limit for that date. Decline this request or raise your limit.'"
    #expect(Planner.paused(["is_error": false, "result": result], out: "", now: now) == nil)
  }

  @Test func anErrorThatIsNotALimitIsNotWaitedOn() {
    #expect(Planner.paused(["is_error": true, "result": "API Error: 500 Internal Server Error"], out: "", now: now) == nil)
  }
}

@MainActor
struct RunningPullRequests {
  @Test func aSessionNamedForAPullRequestCountsAsWorkingOnIt() {
    #expect(Store.names(150, in: "bring-pull-request-150"))
    #expect(Store.names(141, in: "fix-pr-141"))
    #expect(Store.names(150, in: "Unblock PR #150"))
    #expect(Store.names(150, in: "Bring pull request #150 (fix(help): the) up to date with main"))
  }

  @Test func anotherNumberIsNotThatPullRequest() {
    #expect(!Store.names(150, in: "fix-pr-1500"))
    #expect(!Store.names(15, in: "Unblock PR #150"))
    #expect(!Store.names(150, in: "Run 150 tests"))
  }

  @Test func everyPullRequestAnIdeaNamesIsFound() {
    #expect(Store.prs(in: "Unblock PR #150 then #143") == [150, 143])
  }
}
