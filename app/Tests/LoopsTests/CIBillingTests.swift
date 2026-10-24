import Foundation
import Testing

@testable import Loops

private let billingMessage =
  "The job was not started because recent account payments have failed or your spending limit needs to be increased. Please check the 'Billing & plans' section in your settings"
private let migrationNotice =
  "\"The ubuntu-latest label will migrate to Ubuntu 26 beginning October 19, 2026. For more information, see https://github.com/actions/runner-images/issues/14748\""

private func json(_ value: Any) -> String {
  String(decoding: (try? JSONSerialization.data(withJSONObject: value)) ?? Data(), as: UTF8.self)
}

private func annotations(_ messages: (level: String, text: String)...) -> String {
  json(
    messages.map {
      [
        "path": ".github", "start_line": 1, "end_line": 1, "annotation_level": $0.level, "title": "", "message": $0.text,
        "raw_details": "",
      ]
    })
}

private func job(_ id: Int, _ name: String, conclusion: String?, status: String = "completed", hosted: Bool = true, steps: Int = 0)
  -> [String: Any]
{
  [
    "id": id, "name": name, "status": status, "conclusion": conclusion ?? NSNull(),
    "labels": hosted ? ["ubuntu-latest"] : ["self-hosted", "macOS"], "runner_name": steps > 0 ? "mac-runner-1" : "",
    "steps": (0..<steps).map { ["name": "step \($0)", "status": "completed", "conclusion": "success", "number": $0 + 1] },
    "html_url": "https://github.com/acme/shop/actions/runs/1/job/\(id)",
  ]
}

private func run(_ id: Int, _ branch: String, status: String = "completed", conclusion: String?) -> [String: Any] {
  [
    "databaseId": id, "workflowName": "Check", "displayTitle": "Run \(id)", "headBranch": branch, "event": "push", "status": status,
    "conclusion": conclusion ?? "", "startedAt": "2026-10-11T08:45:36Z", "updatedAt": "2026-10-11T08:45:40Z",
    "url": "https://github.com/acme/shop/actions/runs/\(id)",
  ]
}

private struct Fixture {
  var list: [[String: Any]] = []
  var jobs: [Int: [[String: Any]]] = [:]
  var notes: [Int: String] = [:]

  mutating func add(_ run: [String: Any], jobs: [[String: Any]] = [], notes: [Int: String] = [:]) {
    list.append(run)
    if let id = run["databaseId"] as? Int { self.jobs[id] = jobs }
    self.notes.merge(notes) { $1 }
  }

  var runs: [CIRun] {
    (CI.runs(json(list)) ?? []).map { r in
      var r = r
      r.jobs = CI.jobs(json(["total_count": jobs[r.id]?.count ?? 0, "jobs": jobs[r.id] ?? []])).map {
        $0.classified(notes.compactMapValues(CI.billing))
      }
      return r
    }
  }

  var board: CIBoard { CIBoard(runs) }
}

private func blockedRun(_ id: Int, into f: inout Fixture, message: String = billingMessage) {
  let a = id * 10 + 1
  let b = id * 10 + 2
  f.add(
    run(id, "main", conclusion: "failure"),
    jobs: [job(a, "lint", conclusion: "failure"), job(b, "test", conclusion: "failure")],
    notes: [
      a: annotations(("failure", message), ("notice", migrationNotice)),
      b: annotations(("failure", message)),
    ])
}

@Suite struct BillingClassification {
  @Test func aBillingAnnotationBlocksTheRun() {
    var f = Fixture()
    blockedRun(1, into: &f)
    let r = f.runs[0]
    #expect(r.jobs.filter { $0.billing == true }.count == 2)
    #expect(r.billingBlocked)
    #expect(f.board.blocked.map(\.id) == [1])
  }

  @Test func aSpendingLimitAnnotationBlocksTheRun() {
    var f = Fixture()
    blockedRun(1, into: &f, message: "The job was not started because your spending limit needs to be increased.")
    #expect(f.runs[0].billingBlocked)
    #expect(f.board.blocked.map(\.id) == [1])
  }

  @Test func aStartupFailureWithoutABillingAnnotationIsNotBlocked() {
    var f = Fixture()
    f.add(
      run(1, "main", conclusion: "startup_failure"),
      jobs: [job(11, "lint", conclusion: "startup_failure", hosted: false)],
      notes: [11: annotations(("failure", "Invalid workflow file: .github/workflows/check.yml#L12: unexpected value 'runs_on'"))])
    #expect(!f.runs[0].billingBlocked)
    #expect(f.board.blocked.isEmpty)
    #expect(f.board.rows.map(\.id) == [1])
  }

  @Test func aHostedJobThatNeverStartedWithoutTheAnnotationStaysInTheNeverStartedCard() {
    var f = Fixture()
    f.add(
      run(1, "feature", conclusion: "failure"),
      jobs: [job(11, "lint", conclusion: "failure")],
      notes: [11: annotations(("notice", migrationNotice))])
    #expect(!f.runs[0].billingBlocked)
    #expect(f.board.blocked.isEmpty)
    #expect(f.board.neverStarted.map(\.id) == [1])
    #expect(f.board.rows.isEmpty)
  }

  @Test func aJobWithNoAnnotationsFetchedIsNotBilling() {
    var f = Fixture()
    f.add(run(1, "feature", conclusion: "failure"), jobs: [job(11, "lint", conclusion: "failure")])
    #expect(!f.runs[0].billingBlocked)
    #expect(!f.runs[0].settled)
    #expect(f.board.neverStarted.map(\.id) == [1])
  }

  @Test func anUnreadableAnnotationResponseLeavesTheRunToBeReadAgain() {
    var f = Fixture()
    f.add(
      run(1, "main", conclusion: "failure"),
      jobs: [job(11, "lint", conclusion: "failure"), job(12, "test", conclusion: "failure")],
      notes: [11: annotations(("failure", billingMessage)), 12: "gh: Server Error (HTTP 502)"])
    #expect(CI.billing("gh: Server Error (HTTP 502)") == nil)
    #expect(f.runs[0].jobs.map(\.billing) == [true, nil])
    #expect(!f.runs[0].billingBlocked)
    #expect(!f.runs[0].settled)
  }

  @Test func aFinishedRunIsSettledOnceEveryRefusedJobHasItsAnnotationsRead() {
    var f = Fixture()
    blockedRun(2, into: &f)
    f.add(
      run(1, "feature", conclusion: "failure"),
      jobs: [job(11, "lint", conclusion: "failure"), job(12, "test", conclusion: "failure", hosted: false, steps: 3)],
      notes: [11: annotations(("notice", migrationNotice))])
    #expect(f.runs.map(\.settled) == [true, true])
  }

  @Test func aRunStillInProgressIsNotSettled() {
    var f = Fixture()
    f.add(
      run(1, "main", status: "in_progress", conclusion: nil),
      jobs: [job(11, "lint", conclusion: "failure"), job(12, "test", conclusion: nil, status: "in_progress", hosted: false, steps: 2)],
      notes: [11: annotations(("failure", billingMessage))])
    #expect(!f.runs[0].settled)
  }

  @Test func aRunIsBlockedOnlyWhenEveryFailedJobIsBilling() {
    var f = Fixture()
    f.add(
      run(1, "main", conclusion: "failure"),
      jobs: [job(11, "lint", conclusion: "failure"), job(12, "test", conclusion: "failure", hosted: false, steps: 3)],
      notes: [11: annotations(("failure", billingMessage))])
    #expect(!f.runs[0].billingBlocked)
    #expect(f.board.blocked.isEmpty)
  }
}

@Suite struct BillingBlockState {
  @Test func theCardCoversTheNewestConsecutiveBlockedRuns() {
    var f = Fixture()
    blockedRun(3, into: &f)
    blockedRun(2, into: &f)
    f.add(run(1, "main", conclusion: "success"))
    #expect(f.board.blocked.map(\.id) == [3, 2])
    #expect(f.board.rows.map(\.id) == [1])
    #expect(f.board.neverStarted.isEmpty)
  }

  @Test func aBlockedRunWhoseOtherJobStartedStillShowsTheCard() {
    var f = Fixture()
    f.add(
      run(2, "main", conclusion: "failure"),
      jobs: [job(21, "lint", conclusion: "failure"), job(22, "test", conclusion: "success", hosted: false, steps: 3)],
      notes: [21: annotations(("failure", billingMessage))])
    blockedRun(1, into: &f)
    #expect(f.board.blocked.map(\.id) == [2])
    #expect(f.board.rows.map(\.id) == [1])
  }

  @Test func aNewerRunWithAStartedJobClearsTheState() {
    var f = Fixture()
    f.add(
      run(2, "main", conclusion: "failure"),
      jobs: [job(21, "test", conclusion: "failure", hosted: false, steps: 4)])
    blockedRun(1, into: &f)
    #expect(f.board.blocked.isEmpty)
  }

  @Test func aNewerRunStillInProgressOnAStartedJobClearsTheState() {
    var f = Fixture()
    f.add(
      run(2, "main", status: "in_progress", conclusion: nil),
      jobs: [job(21, "test", conclusion: nil, status: "in_progress", hosted: false, steps: 2)])
    blockedRun(1, into: &f)
    #expect(f.board.blocked.isEmpty)
  }

  @Test func aNewerQueuedRunThatHasNotStartedLeavesTheStateBlocked() {
    var f = Fixture()
    f.add(run(3, "main", status: "queued", conclusion: nil), jobs: [job(31, "lint", conclusion: nil, status: "queued")])
    blockedRun(2, into: &f)
    f.add(run(1, "main", conclusion: "success"))
    #expect(f.board.blocked.map(\.id) == [2])
    #expect(f.board.rows.map(\.id) == [3, 1])
  }

  @Test func olderBlockedRunsBehindAClearRunShowAsRows() {
    var f = Fixture()
    f.add(run(4, "main", conclusion: "success"))
    blockedRun(3, into: &f)
    blockedRun(2, into: &f)
    f.add(run(1, "feature", conclusion: "failure"), jobs: [job(11, "lint", conclusion: "failure")])
    let board = f.board
    #expect(board.blocked.isEmpty)
    #expect(board.rows.map(\.id) == [4, 3, 2])
    #expect(board.rows.filter(\.billingBlocked).map(\.id) == [3, 2])
    #expect(board.neverStarted.map(\.id) == [1])
  }

  @Test func skippedRunsAreLeftOut() {
    var f = Fixture()
    f.add(run(2, "main", conclusion: "skipped"))
    blockedRun(1, into: &f)
    #expect(f.runs.map(\.id) == [1])
    #expect(f.board.blocked.map(\.id) == [1])
  }
}

@Suite struct BillingSettings {
  @Test func aUserOwnerOpensTheAccountBillingPage() {
    let owner = json(["login": "octocat", "type": "User"])
    #expect(CI.billingURL(owner)?.absoluteString == "https://github.com/settings/billing")
  }

  @Test func anOrganizationOwnerOpensTheOrganizationBillingPage() {
    let owner = json(["login": "acme", "type": "Organization"])
    #expect(CI.billingURL(owner)?.absoluteString == "https://github.com/organizations/acme/settings/billing")
  }

  @Test func anUnreadableOwnerOpensNothing() {
    #expect(CI.billingURL("gh: Not Found (HTTP 404)") == nil)
  }
}
