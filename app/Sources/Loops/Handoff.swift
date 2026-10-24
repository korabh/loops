import Foundation
import Observation
import SwiftUI

struct Readiness: Equatable {
  let buildable: Bool
  let missing: [String]
}

enum Handoff: Equatable {
  case open
  case queued
  case claimed(String)
  case building
  case review(PullRequest)
}

@MainActor @Observable
final class Handoffs {

  private(set) var checking: Set<Int> = []
  private(set) var queuing: Set<Int> = []
  private(set) var readiness: [Int: Readiness] = [:]
  private(set) var usage = Usage()
  var failure: [Int: String] = [:]

  private static let schema =
    #"{"type":"object","additionalProperties":false,"required":["buildable","missing"],"properties":{"buildable":{"type":"boolean"},"missing":{"type":"array","maxItems":4,"items":{"type":"string"}}}}"#

  func build(_ issue: Issue, store: Store) async {
    guard !checking.contains(issue.number), !queuing.contains(issue.number) else { return }
    if await check(issue, store: store)?.buildable == true { await queue(issue, store: store) }
  }

  func check(_ issue: Issue, store: Store) async -> Readiness? {
    checking.insert(issue.number)
    failure[issue.number] = nil
    defer { checking.remove(issue.number) }
    let (code, out) = await Shell.exec(["gh", "issue", "view", String(issue.number), "--json", "title,body"], in: store.paths.repo)
    guard code == 0, let obj = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any] else {
      failure[issue.number] = "Couldn't read the issue from GitHub."
      return nil
    }
    let prompt = """
      The Issue builder loop builds a GitHub issue only when every acceptance criterion in it can be checked by a test or a command, so it never has to ask a question. Read this issue and say whether it is buildable as written. If not, list what is missing as short phrases a person can act on, at most four.

      #\(issue.number) \(obj["title"] as? String ?? issue.title)

      \(obj["body"] as? String ?? "")
      """
    let (_, res) = await Shell.exec(
      [
        "claude", "-p", "--model", "haiku", "--effort", "low", "--tools", "", "--no-session-persistence", "--disable-slash-commands",
        "--output-format", "json", "--json-schema", Self.schema, prompt,
      ], in: store.paths.repo, config: store.config)
    let json = res.split(separator: "\n").last { $0.hasPrefix("{") }.map(String.init) ?? ""
    guard let result = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
      let s = result["structured_output"] as? [String: Any], let buildable = s["buildable"] as? Bool
    else {
      failure[issue.number] = "Claude Code couldn't check the issue."
      return nil
    }
    usage = usage + Usage(result: result)
    let r = Readiness(buildable: buildable, missing: s["missing"] as? [String] ?? [])
    readiness[issue.number] = r
    return r
  }

  func queue(_ issue: Issue, store: Store) async {
    await label(issue, add: true, store: store)
  }

  func unqueue(_ issue: Issue, store: Store) async {
    await label(issue, add: false, store: store)
  }

  private func label(_ issue: Issue, add: Bool, store: Store) async {
    queuing.insert(issue.number)
    defer { queuing.remove(issue.number) }
    let (code, out) = await Shell.exec(
      ["gh", "issue", "edit", String(issue.number), add ? "--add-label" : "--remove-label", "ready-for-agent"], in: store.paths.repo)
    if code != 0 {
      failure[issue.number] = out.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init) ?? "gh issue edit failed."
      return
    }
    if add { readiness[issue.number] = nil }
    await store.refreshGitHub()
  }
}

extension Store {
  func handoff(_ issue: Issue) -> Handoff {
    if let pr = pulls.values.filter({ $0.open && $0.issues.contains(issue.number) }).max(by: { $0.number < $1.number }) { return .review(pr) }
    let builder = "loop-issue-queue"
    if tasks.contains(where: { $0.key == "build:\(issue.number)" && $0.active }) || (isStarting(builder) && issue.labels.contains("ready-for-agent")) {
      return .building
    }
    if let who = issue.assignees.first { return .claimed(who) }
    return issue.labels.contains("ready-for-agent") ? .queued : .open
  }

  var handoffIssues: [Issue] {
    issues.values.filter(\.open).sorted { $0.number > $1.number }
  }

  var builderBusy: Bool { running["loop-issue-queue"] != nil }

  func buildNow(_ issue: Issue) {
    let loop = "loop-issue-queue"
    let handoffs = self.handoffs
    handoffs.failure[issue.number] = nil
    guard !builderBusy else {
      handoffs.failure[issue.number] = "Issue builder is on another issue. It takes #\(issue.number) on a later run."
      return
    }
    launch(
      "/\(loop) \(issue.number)", name: "Issue builder: #\(issue.number)", loop: loop, in: paths.runner, worktree: nil,
      key: "build:\(issue.number)"
    ) { ok in
      if !ok { handoffs.failure[issue.number] = self.notice ?? "Couldn't start Issue builder." }
    }
  }
}

@MainActor func sharpen(_ issue: Issue, store: Store) {
  guard store.planner.proposal == nil else {
    store.notice = "Finish or start over the proposal in progress before sharpening #\(issue.number)."
    return
  }
  store.planner.start("#\(issue.number) \(issue.title)", target: issue.number, store: store)
}
