import AppKit
import Foundation
import Observation

struct CIJob: Identifiable, Equatable {
  let id: Int
  let name: String
  let status: String
  let conclusion: String?
  let runner: String?
  let hosted: Bool
  let started: Bool
  let url: URL?
  var billing: Bool?

  var failed: Bool { ["failure", "timed_out", "startup_failure"].contains(conclusion ?? "") }
  var refused: Bool { failed && !started }

  func classified(_ billed: [Int: Bool]) -> CIJob {
    var job = self
    job.billing = refused ? billed[id] : false
    return job
  }
}

struct CIRun: Identifiable, Equatable {
  let id: Int
  let workflow: String
  let title: String
  let branch: String
  let event: String
  let status: String
  let conclusion: String?
  let started: Date?
  let updated: Date?
  let url: URL
  var jobs: [CIJob] = []

  var active: Bool { status != "completed" }
  var failed: Bool { ["failure", "timed_out", "startup_failure"].contains(conclusion ?? "") }
  var neverRan: Bool { failed && !jobs.isEmpty && jobs.allSatisfy { !$0.started } }
  var hosted: Bool { jobs.contains(where: \.hosted) }
  var billingBlocked: Bool {
    let failing = jobs.filter(\.failed)
    return failed && !failing.isEmpty && failing.allSatisfy { $0.billing == true }
  }
  var settled: Bool { !active && jobs.allSatisfy { !$0.refused || $0.billing != nil } }
  var stuck: Bool { neverRan && hosted && !billingBlocked }
  var ranJob: Bool { conclusion == "success" || jobs.contains(where: \.started) }
}

struct CIBoard {
  let blocked: [CIRun]
  let neverStarted: [CIRun]
  let rows: [CIRun]

  init(_ runs: [CIRun]) {
    var blocked: [CIRun] = []
    for run in runs {
      if run.billingBlocked { blocked.append(run) }
      if run.ranJob { break }
    }
    let ids = Set(blocked.map(\.id))
    self.blocked = blocked
    neverStarted = runs.filter(\.stuck)
    rows = runs.filter { !ids.contains($0.id) && !$0.stuck }
  }
}

struct StaleRun: Identifiable, Equatable {
  let run: CIRun
  let why: String
  let merged: Bool

  var id: Int { run.id }
}

struct Runner: Identifiable, Equatable {
  let id: Int
  let name: String
  let online: Bool
  let busy: Bool
  var service: String?
  var loaded = false
  var pid: Int?
  var job: CIJob?

  var short: String { name.split(separator: "-").last.map { "Runner \($0)" } ?? name }
}

@MainActor @Observable
final class CI {

  private(set) var runners: [Runner] = []
  private(set) var runs: [CIRun] = []
  private(set) var loaded = false
  private(set) var mainSelfHosted = false
  private(set) var acting = Set<String>()
  private(set) var stale: [StaleRun] = []
  private(set) var cancelled = 0
  private(set) var cancelling = 0
  var notice: String?
  private(set) var billingProblem: String?
  private(set) var board = CIBoard([])
  @ObservationIgnored private var finished: [Int: [CIJob]] = [:]
  @ObservationIgnored private var billed: [Int: Bool] = [:]
  @ObservationIgnored private var billingPage: URL?
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var refreshed: Date?

  func refreshIfStale(store: Store) async {
    if Date().timeIntervalSince(refreshed ?? .distantPast) > 45 { await refresh(store: store) }
  }

  func refresh(store: Store) async {
    generation += 1
    let mine = generation
    refreshed = Date()
    let repo = store.paths.repo
    async let r = Shell.exec(["gh", "api", "repos/{owner}/{repo}/actions/runners"], in: repo)
    async let l = Shell.exec(
      [
        "gh", "run", "list", "--limit", "100", "--json",
        "databaseId,workflowName,displayTitle,headBranch,event,status,conclusion,startedAt,updatedAt,url",
      ], in: repo)
    async let s = Shell.exec(["launchctl", "list"], in: repo)
    let workflow = store.project?.ci?.workflow ?? ""
    async let w = Shell.exec(["git", "show", "origin/main:.github/workflows/\(workflow)"], in: repo)
    let (rc, ro) = await r
    let (lc, lo) = await l
    let (_, so) = await s
    let (wc, wo) = await w
    defer { loaded = true }
    mainSelfHosted = !workflow.isEmpty && wc == 0 && wo.contains("self-hosted")
    guard lc == 0, let all = Self.all(lo) else { return }
    let old = Self.stale(all, pulls: store.pulls)
    if old != stale { stale = old }
    var next = Self.recent(all)
    for i in next.indices where next[i].active || next[i].failed {
      if let cached = finished[next[i].id] {
        next[i].jobs = cached
        continue
      }
      guard let jobs = await jobs(next[i].id, in: repo) else { continue }
      next[i].jobs = jobs
      if next[i].settled { finished[next[i].id] = jobs }
    }
    guard mine == generation else { return }
    let shown = Set(next.flatMap { $0.jobs.map(\.id) })
    billed = billed.filter { shown.contains($0.key) }
    let services = Self.services(so)
    var found: [Runner] = []
    if rc == 0, let obj = (try? JSONSerialization.jsonObject(with: Data(ro.utf8))) as? [String: Any] {
      for x in obj["runners"] as? [[String: Any]] ?? [] {
        guard let id = x["id"] as? Int, let name = x["name"] as? String else { continue }
        var runner = Runner(id: id, name: name, online: x["status"] as? String == "online", busy: x["busy"] as? Bool ?? false)
        if let svc = services.first(where: { $0.label.hasSuffix(".\(name)") }) {
          runner.service = svc.label
          runner.loaded = true
          runner.pid = svc.pid
        } else if let label = Self.installed().first(where: { $0.hasSuffix(".\(name)") }) {
          runner.service = label
        }
        for run in next where run.active {
          if let job = run.jobs.first(where: { $0.runner == name && $0.status == "in_progress" }) { runner.job = job }
        }
        found.append(runner)
      }
    }
    found.sort { $0.name < $1.name }
    if found != runners { runners = found }
    if next != runs {
      runs = next
      board = CIBoard(next)
    }
  }

  private func jobs(_ run: Int, in repo: URL) async -> [CIJob]? {
    let (code, out) = await Shell.exec(["gh", "api", "repos/{owner}/{repo}/actions/runs/\(run)/jobs"], in: repo)
    guard code == 0 else { return nil }
    let jobs = Self.jobs(out)
    await withTaskGroup(of: (Int, Bool?).self) { group in
      for job in jobs where job.refused && billed[job.id] == nil {
        group.addTask {
          let (c, o) = await Shell.exec(["gh", "api", "repos/{owner}/{repo}/check-runs/\(job.id)/annotations"], in: repo)
          return (job.id, c == 0 ? Self.billing(o) : nil)
        }
      }
      for await (id, billing) in group {
        if let billing { billed[id] = billing }
      }
    }
    return jobs.map { $0.classified(billed) }
  }

  nonisolated static func jobs(_ json: String) -> [CIJob] {
    guard let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { return [] }
    return (obj["jobs"] as? [[String: Any]] ?? []).compactMap { j in
      guard let id = j["id"] as? Int, let name = j["name"] as? String else { return nil }
      let labels = j["labels"] as? [String] ?? []
      let runner = (j["runner_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
      return CIJob(
        id: id, name: name, status: j["status"] as? String ?? "", conclusion: j["conclusion"] as? String, runner: runner,
        hosted: !labels.isEmpty && !labels.contains("self-hosted"), started: !(j["steps"] as? [Any] ?? []).isEmpty,
        url: (j["html_url"] as? String).flatMap(URL.init(string:)))
    }
  }

  nonisolated static func billing(_ annotations: String) -> Bool? {
    guard let list = (try? JSONSerialization.jsonObject(with: Data(annotations.utf8))) as? [[String: Any]] else { return nil }
    return list.contains { a in
      let message = (a["message"] as? String ?? "").lowercased()
      return ["account payments have failed", "spending limit", "billing issue"].contains { message.contains($0) }
    }
  }

  nonisolated static func all(_ json: String) -> [CIRun]? {
    guard let list = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: Any]] else { return nil }
    return list.compactMap(run)
  }

  nonisolated static func runs(_ json: String) -> [CIRun]? { all(json).map(recent) }

  nonisolated static func recent(_ runs: [CIRun]) -> [CIRun] { Array(runs.filter { $0.conclusion != "skipped" }.prefix(20)) }

  nonisolated private static func run(_ x: [String: Any]) -> CIRun? {
    guard let id = x["databaseId"] as? Int, let url = (x["url"] as? String).flatMap(URL.init(string:)) else { return nil }
    return CIRun(
      id: id, workflow: x["workflowName"] as? String ?? "", title: x["displayTitle"] as? String ?? "",
      branch: x["headBranch"] as? String ?? "", event: x["event"] as? String ?? "", status: x["status"] as? String ?? "",
      conclusion: (x["conclusion"] as? String).flatMap { $0.isEmpty ? nil : $0 },
      started: (x["startedAt"] as? String).flatMap(Reader.date), updated: (x["updatedAt"] as? String).flatMap(Reader.date), url: url)
  }

  nonisolated static func billingURL(_ owner: String) -> URL? {
    guard let obj = (try? JSONSerialization.jsonObject(with: Data(owner.utf8))) as? [String: Any], let login = obj["login"] as? String
    else { return nil }
    return URL(
      string: obj["type"] as? String == "Organization"
        ? "https://github.com/organizations/\(login)/settings/billing" : "https://github.com/settings/billing")
  }

  private static var agents: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents") }

  private static func installed() -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: agents.path)) ?? [])
      .filter { $0.hasPrefix("actions.runner.") && $0.hasSuffix(".plist") }
      .map { String($0.dropLast(6)) }
  }

  private static func services(_ out: String) -> [(label: String, pid: Int?)] {
    out.split(separator: "\n").compactMap { line in
      let cols = line.split(separator: "\t").map(String.init)
      guard cols.count == 3, cols[2].hasPrefix("actions.runner.") else { return nil }
      return (cols[2], Int(cols[0]))
    }
  }

  func pull(for run: CIRun, store: Store) -> PullRequest? {
    store.pulls.values.first { $0.open && $0.headRefName == run.branch }
  }

  func stuckPulls(store: Store) -> [PullRequest] {
    var seen = Set<String>()
    return runs.compactMap { run in
      guard seen.insert(run.branch).inserted, run.stuck else { return nil }
      return pull(for: run, store: store)
    }
  }

  func updateBranches(_ prs: [PullRequest], store: Store) {
    act("branches", store: store, prs.map { ("#\($0.number)", ["gh", "pr", "update-branch", String($0.number)]) }, settle: 3)
  }

  func rerunFailed(_ runs: [CIRun], store: Store) {
    act("billing-rerun", store: store, runs.map { ("\($0.workflow) on \($0.branch)", Self.rerun($0, failed: true)) }, settle: 3)
  }

  func openBilling(store: Store) {
    if let billingPage {
      NSWorkspace.shared.open(billingPage)
      return
    }
    guard !acting.contains("billing-page") else { return }
    acting.insert("billing-page")
    billingProblem = nil
    Task {
      let (code, out) = await Shell.exec(["gh", "api", "repos/{owner}/{repo}", "--jq", ".owner"], in: store.paths.repo)
      acting.remove("billing-page")
      guard code == 0, let url = Self.billingURL(out) else {
        let text = out.trimmingCharacters(in: .whitespacesAndNewlines)
        billingProblem = text.isEmpty ? "gh couldn't say who owns this repository, so Loops can't tell which billing page to open." : text
        return
      }
      billingPage = url
      NSWorkspace.shared.open(url)
    }
  }

  static func stale(_ runs: [CIRun], pulls: [Int: PullRequest]) -> [StaleRun] {
    let active = runs.filter { $0.active && ["push", "pull_request"].contains($0.event) }
    let newest = Dictionary(grouping: active) { "\($0.workflow)|\($0.branch)" }.mapValues { $0.map(\.id).max() ?? 0 }
    return active.compactMap { run in
      let prs = pulls.values.filter { $0.headRefName == run.branch }
      if run.branch != "main", !prs.contains(where: \.open), let pr = prs.max(by: { $0.number < $1.number }) {
        return StaleRun(run: run, why: "#\(pr.number) is \(pr.merged ? "merged" : "closed")", merged: true)
      }
      guard newest["\(run.workflow)|\(run.branch)"] != run.id, run.branch != "main" || run.status != "in_progress" else { return nil }
      return StaleRun(run: run, why: "a newer push to \(run.branch) replaces it", merged: false)
    }
  }

  func cancelStale(store: Store) {
    guard !acting.contains("stale") else { return }
    let list = stale
    acting.insert("stale")
    notice = nil
    cancelled = 0
    cancelling = list.count
    Task {
      var failed: [String] = []
      for s in list {
        let (code, out) = await Shell.exec(["gh", "run", "cancel", String(s.run.id)], in: store.paths.repo)
        if code != 0, !out.localizedCaseInsensitiveContains("completed") {
          failed.append("\(s.run.workflow) on \(s.run.branch): \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        cancelled += 1
      }
      if !failed.isEmpty { notice = failed.joined(separator: "\n") }
      try? await Task.sleep(for: .seconds(3))
      finished = [:]
      await refresh(store: store)
      acting.remove("stale")
    }
  }

  func rerun(_ run: CIRun, failed: Bool, store: Store) {
    act("run:\(run.id)", store: store, Self.rerun(run, failed: failed))
  }

  private static func rerun(_ run: CIRun, failed: Bool) -> [String] {
    ["gh", "run", "rerun", String(run.id)] + (failed ? ["--failed"] : [])
  }

  func cancel(_ run: CIRun, store: Store) {
    act("run:\(run.id)", store: store, ["gh", "run", "cancel", String(run.id)])
  }

  func updateBranch(_ pr: PullRequest, store: Store) {
    act("pr:\(pr.number)", store: store, ["gh", "pr", "update-branch", String(pr.number)])
  }

  func restart(_ runner: Runner, store: Store) {
    guard let service = runner.service else { return }
    let domain = "gui/\(getuid())"
    var commands: [(label: String?, command: [String])] = []
    if !runner.loaded {
      commands.append(("load \(runner.short)", ["launchctl", "bootstrap", domain, Self.agents.appending(path: "\(service).plist").path]))
    }
    commands.append(("start \(runner.short)", ["launchctl", "kickstart", "-k", "\(domain)/\(service)"]))
    act("runner:\(runner.id)", store: store, commands, settle: 2)
  }

  func showLog(_ runner: Runner) {
    guard let service = runner.service else { return }
    NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/\(service)"))
  }

  private func act(_ key: String, store: Store, _ command: [String]) {
    act(key, store: store, [(nil, command)], settle: 2)
  }

  private func act(_ key: String, store: Store, _ commands: [(label: String?, command: [String])], settle: Double) {
    guard !acting.contains(key) else { return }
    acting.insert(key)
    notice = nil
    Task {
      var failed: [String] = []
      for (label, command) in commands {
        let (code, out) = await Shell.exec(command, in: store.paths.repo)
        let text = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if code != 0 { failed.append(label.map { "\($0): \(text)" } ?? text) }
      }
      if !failed.isEmpty { notice = failed.joined(separator: "\n") }
      try? await Task.sleep(for: .seconds(settle))
      finished = [:]
      await refresh(store: store)
      acting.remove(key)
    }
  }
}

struct CIProblem: Identifiable, Equatable {
  enum Kind { case billing, runners, stale, stuck }

  let id: String
  let kind: Kind
  let title: String
  let detail: String
  let at: Date?
  let action: String?
}

extension CI {
  static let billingHelp =
    "GitHub refused to start these jobs: an account payment failed or the Actions spending limit was reached. It isn't a code failure. Fix the payment or raise the limit, then re-run."

  var offline: [Runner] { runners.filter { !$0.online } }

  var queued: Int { runs.filter { $0.active && $0.status != "in_progress" }.count }

  var problems: [CIProblem] {
    var out: [CIProblem] = []
    if !board.blocked.isEmpty {
      out.append(
        CIProblem(
          id: "billing", kind: .billing, title: "GitHub won't start jobs: billing is blocked", detail: Self.billingHelp,
          at: board.blocked.last?.started, action: "Fix Billing"))
    }
    let down = offline
    if !down.isEmpty, queued > 0 || down.count == runners.count {
      out.append(
        CIProblem(
          id: "runners", kind: .runners,
          title: down.count == runners.count ? "\(plural(down.count, "runner")) offline" : "\(down.count) of \(runners.count) runners offline",
          detail: queued > 0 ? "\(plural(queued, "run")) waiting for a runner" : "Checks can't run on this Mac",
          at: nil, action: down.contains { $0.service != nil } ? (down.count == 1 ? "Start" : "Start All") : nil))
    }
    if !stale.isEmpty {
      out.append(
        CIProblem(
          id: "stale", kind: .stale,
          title: stale.count == 1 ? "1 stale run is holding a runner" : "\(stale.count) stale runs are holding runners",
          detail: stale.map { "\($0.run.workflow) on \($0.run.branch): \($0.why)" }.joined(separator: "\n"),
          at: stale.compactMap(\.run.started).min(),
          action: stale.count == 1 ? "Cancel It" : "Cancel \(stale.count)"))
    }
    if !board.neverStarted.isEmpty {
      out.append(
        CIProblem(
          id: "stuck", kind: .stuck,
          title: "\(plural(board.neverStarted.count, "run")) never started on GitHub's runners",
          detail: "They asked for GitHub's runners instead of this Mac. Updating their branches from main moves them here.",
          at: board.neverStarted.compactMap(\.started).min(),
          action: mainSelfHosted ? "Update Branches" : nil))
    }
    return out
  }

  func perform(_ p: CIProblem, store: Store) {
    switch p.kind {
    case .billing: openBilling(store: store)
    case .runners: for r in offline where r.service != nil { restart(r, store: store) }
    case .stale: cancelStale(store: store)
    case .stuck: updateBranches(stuckPulls(store: store), store: store)
    }
  }

  func busy(_ p: CIProblem) -> Bool {
    switch p.kind {
    case .billing: acting.contains("billing-page") || acting.contains("billing-rerun")
    case .runners: offline.contains { acting.contains("runner:\($0.id)") }
    case .stale: acting.contains("stale")
    case .stuck: acting.contains("branches")
    }
  }
}
