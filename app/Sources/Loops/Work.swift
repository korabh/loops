import AppKit
import Foundation

struct Item: Identifiable {
  enum Kind: Int { case merge, review, decide }

  let id: String
  let kind: Kind
  let pr: PullRequest?
  let asks: [Ask]

  var at: Date { asks.map(\.at).max() ?? .distantPast }
  var loops: [String] { asks.map(\.loop).reduce(into: []) { if !$0.contains($1) { $0.append($1) } } }
  var claude: URL? { asks.compactMap(\.url).first { $0.scheme == "claude-cli" } }

  var headline: String {
    if let pr { return pr.tidyTitle }
    return capitalizedFirst(Briefs.sentences(asks.first?.text ?? "").first ?? "")
  }

  var notes: [(loop: String, text: String)] {
    if let pr {
      return asks.map { a in
        let t = a.text.hasPrefix("#\(pr.number) ") ? String(a.text.dropFirst("#\(pr.number) ".count)) : a.text
        return (a.loop, capitalizedFirst(t))
      }
    }
    guard let a = asks.first else { return [] }
    let rest = Briefs.sentences(a.text).dropFirst().joined(separator: " ")
    return rest.isEmpty ? [] : [(a.loop, rest)]
  }
}

struct Step: Identifiable {
  enum Mark { case done, active, failed, todo }

  let label: String
  let mark: Mark

  var id: String { label }
}

enum Stage: Int, CaseIterable, Identifiable {
  case queued, building, fixing, review, ready, done

  var id: Int { rawValue }

  var title: String {
    switch self {
    case .queued: "Queued"
    case .building: "Building"
    case .fixing: "Needs fixes"
    case .review: "In review"
    case .ready: "Ready to merge"
    case .done: "Done"
    }
  }

  var hint: String {
    switch self {
    case .queued: "Filed and waiting for a loop to pick it up"
    case .building: "A loop is working on it, or checks are still running"
    case .fixing: "Failing checks or review items; PR fixer takes these"
    case .review: "Waiting for PR reviewer to look at the latest commit"
    case .ready: "Checks pass and the review is happy"
    case .done: "Merged or closed"
    }
  }

  var symbol: String {
    switch self {
    case .queued: "hourglass"
    case .building: "hammer"
    case .fixing: "wrench.and.screwdriver"
    case .review: "eye"
    case .ready: "checkmark.seal"
    case .done: "checkmark.circle"
    }
  }
}

struct Outcome: Identifiable {
  enum Kind { case pull, issue }

  let kind: Kind
  let number: Int
  let loop: String
  let title: String
  let url: URL
  let at: Date
  let steps: [Step]
  let status: String
  let done: Bool
  var stage: Stage = .done
  var pr: PullRequest?
  var fixes: Int?
  var badge = ""
  var actor: String?
  var when: Date?
  var note: String?

  var needsYou: Bool { !done && actor == "You" }

  var id: String { "\(kind == .pull ? "pr" : "issue")-\(number)" }
}

enum MergeState: Equatable {
  case merged, closed, draft, failing(Int), checking, conflicting, unreviewed, rereview, fixes(Int?), behind, blocked(String), ready

  static func of(_ pr: PullRequest, reviewed: String?, verdict: String?) -> MergeState {
    if pr.merged { return .merged }
    if !pr.open { return .closed }
    if pr.isDraft { return .draft }
    if pr.checks.failed > 0 { return .failing(pr.checks.failed) }
    if pr.checks.pending > 0 { return .checking }
    if pr.mergeable == "CONFLICTING" || pr.mergeStateStatus == "DIRTY" { return .conflicting }
    guard let reviewed else { return .unreviewed }
    if reviewed != pr.headRefOid { return .rereview }
    let lowered = (verdict ?? "").lowercased()
    if ["after", "act on", "not ready", "fix"].contains(where: lowered.contains) {
      return .fixes(Reader.groups(#"(\d+) (?:requested |more )?fix"#, in: verdict ?? "").first.flatMap(Int.init))
    }
    if pr.mergeStateStatus == "BEHIND" { return .behind }
    if let hard = pr.blocker { return .blocked(hard) }
    return .ready
  }

  var title: String {
    switch self {
    case .merged: "Merged"
    case .closed: "Closed"
    case .draft: "Draft"
    case .failing(let n): n == 1 ? "1 check failing" : "\(n) checks failing"
    case .checking: "Checks running"
    case .conflicting: "Conflicts with main"
    case .unreviewed: "Not reviewed yet"
    case .rereview: "New commits since the review"
    case .fixes(let n): n.map { $0 == 1 ? "Review wants 1 fix" : "Review wants \($0) fixes" } ?? "Review wants fixes"
    case .behind: "Behind main"
    case .blocked(let why): capitalizedFirst(why)
    case .ready: "Ready to merge"
    }
  }

  var stage: Stage {
    switch self {
    case .merged, .closed: .done
    case .draft, .checking: .building
    case .failing, .conflicting, .fixes, .behind: .fixing
    case .unreviewed, .rereview: .review
    case .blocked, .ready: .ready
    }
  }

  var mergeable: Bool { self == .ready }
}

extension Stage {
  var priority: Int {
    switch self {
    case .ready: 0
    case .fixing: 1
    case .review: 2
    case .building: 3
    case .queued: 4
    case .done: 5
    }
  }
}

extension Item.Kind {
  var symbol: String {
    switch self {
    case .merge: "arrow.trianglehead.merge"
    case .review: "wrench.adjustable"
    case .decide: "questionmark.bubble"
    }
  }
}

extension Outcome {
  var runner: String? {
    guard !done else { return nil }
    switch actor {
    case "PR fixer": return "loop-pr-fix"
    case "PR reviewer": return "loop-pr-review"
    case "Issue builder": return "loop-issue-queue"
    default: return nil
    }
  }

  var ready: Bool { pr != nil && badge == "Ready" }
}

extension Store {
  func mergeState(_ pr: PullRequest) -> MergeState {
    MergeState.of(pr, reviewed: reviewed[String(pr.number)], verdict: verdicts[pr.number])
  }

  func derive() {
    verdicts = Self.verdicts(briefs)
    reviewedAt = Wait.reviewed(briefs)
    askedAt = Wait.asked(asks, briefs: briefs)
    var groups: [Int: [Ask]] = [:]
    var order: [Int] = []
    var lone: [Item] = []
    for a in asks {
      let named = Briefs.numbers(a.text + " " + (a.url?.absoluteString.removingPercentEncoding ?? ""))
      if let n = named.first(where: { pulls[$0]?.open == true }) {
        if groups[n] == nil { order.append(n) }
        groups[n, default: []].append(a)
      } else {
        lone.append(Item(id: a.id, kind: .decide, pr: nil, asks: [a]))
      }
    }
    let prs = order.compactMap { n -> Item? in
      guard let asks = groups[n], let pr = pulls[n] else { return nil }
      return Item(id: "pr-\(n)", kind: mergeState(pr).mergeable ? .merge : .review, pr: pr, asks: asks)
    }
    items = (prs + lone).sorted {
      ($0.kind.rawValue, $0.pr?.oneWay == true ? 0 : 1, -$0.at.timeIntervalSince1970)
        < ($1.kind.rawValue, $1.pr?.oneWay == true ? 0 : 1, -$1.at.timeIntervalSince1970)
    }
    outcomes = buildOutcomes()
    announce()
  }

  static func verdicts(_ briefs: [Brief]) -> [Int: String] {
    var out: [Int: String] = [:]
    for b in briefs.reversed() where b.loop == "loop-pr-review" {
      for line in b.text.split(separator: "\n") {
        let g = Reader.groups(#"^#(\d+) ([^,(:]+)"#, in: line)
        if g.count == 2, let n = Int(g[0]), out[n] == nil { out[n] = g[1].trimmingCharacters(in: .whitespaces) }
      }
    }
    return out
  }

  var reviewed: [String: String] {
    (states["loop-pr-review"]?.raw["reviewed"] as? [String: String]) ?? [:]
  }

  private func buildOutcomes() -> [Outcome] {
    var out: [Outcome] = []
    let fixer = nextRun["loop-pr-fix"]
    let reviewer = nextRun["loop-pr-review"]
    for pr in pulls.values {
      guard let loop = pr.loop else { continue }
      let state = mergeState(pr)
      let verdict = verdicts[pr.number]
      let current = state != .unreviewed && state != .rereview && reviewed[String(pr.number)] == pr.headRefOid
      let checks: Step.Mark =
        pr.merged || (pr.checks.failed == 0 && pr.checks.pending == 0 && pr.checks.total > 0)
        ? .done : pr.checks.failed > 0 ? .failed : pr.checks.pending > 0 ? .active : .todo
      let (badge, actor, status, when): (String, String?, String, Date?) =
        switch state {
        case .merged: ("Merged", nil, "Merged \(pr.mergedAt.map { Clock.ago($0, now: now) } ?? "")", nil)
        case .closed: ("Closed", nil, "Closed without merging", nil)
        case .draft: ("Draft", title(loop), "\(title(loop)) is still building it", nil)
        case .failing:
          (
            "Checks", "PR fixer",
            "PR fixer fixes \(pr.checks.failing.isEmpty ? "the failing check" : joined(Array(pr.checks.failing.prefix(2))))", fixer
          )
        case .checking: ("Checks", "Checks", "Checks are running", nil)
        case .conflicting: ("Conflicts", "PR fixer", "PR fixer resolves the conflicts with main", fixer)
        case .unreviewed: ("In review", "PR reviewer", "PR reviewer reviews it", reviewer)
        case .rereview: ("Re-review", "PR reviewer", "PR reviewer checks the new commits", reviewer)
        case .fixes(let n): ("Fixing", "PR fixer", "PR fixer takes \(n.map { plural($0, "fix", "fixes") } ?? "the requested fixes")", fixer)
        case .behind: ("Behind main", "PR fixer", "PR fixer updates it from main", fixer)
        case .blocked(let hard): ("Blocked", "You", capitalizedFirst(hard), nil)
        case .ready: ("Ready", "You", "Ready for you to merge", nil)
        }
      let stage = state.stage
      let reviewMark: Step.Mark = pr.merged || current ? .done : stage == .review ? .active : .todo
      let wantsFixes = if case .fixes = state { true } else { false }
      let fixMark: Step.Mark = stage == .fixing ? .active : (pr.merged || stage == .ready || (current && !wantsFixes)) ? .done : .todo
      let mergeMark: Step.Mark = pr.merged ? .done : !pr.open ? .failed : stage == .ready ? .active : .todo
      out.append(
        Outcome(
          kind: .pull, number: pr.number, loop: loop, title: pr.tidyTitle, url: pr.url,
          at: pr.mergedAt ?? pr.closedAt ?? pr.createdAt ?? now,
          steps: [
            Step(label: "Opened", mark: .done), Step(label: "Checks", mark: checks),
            Step(label: "Reviewed", mark: reviewMark), Step(label: "Fixed", mark: fixMark), Step(label: "Merged", mark: mergeMark),
          ], status: status, done: !pr.open, stage: stage, pr: pr, fixes: pr.issue, badge: badge, actor: actor, when: when,
          note: verdict.map { "Review: \(Briefs.readable($0))" }))
    }

    var filed: [Int: (loop: String, at: Date)] = [:]
    let re = try! Regex(#"(?i)\bfiled\b[^#\n]{0,180}#(\d+)"#)
    for b in briefs {
      for m in b.text.matches(of: re) {
        if let n = m.output[1].substring.flatMap({ Int($0) }), filed[n] == nil { filed[n] = (b.loop, b.at) }
      }
    }
    for (n, source) in filed {
      guard let issue = issues[n] else { continue }
      let pr = pulls.values.filter { $0.issue == n }.max { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
      if pr != nil { continue }
      let claimed = !issue.assignees.isEmpty || pr != nil
      let status: String
      if !issue.open {
        status = "Closed \(issue.closedAt.map { Clock.ago($0, now: now) } ?? "")"
      } else if let pr {
        status = pr.merged ? "Fixed in #\(pr.number), merged" : "In #\(pr.number), \(pr.open ? "open" : "closed")"
      } else if claimed {
        status = "Claimed, being built"
      } else if issue.labels.contains("ready-for-agent") {
        status = "Queued for Issue builder"
      } else {
        status = "Filed, waiting for triage"
      }
      out.append(
        Outcome(
          kind: .issue, number: n, loop: source.loop, title: capitalizedFirst(issue.title), url: issue.url,
          at: issue.createdAt ?? source.at,
          steps: [
            Step(label: "Filed", mark: .done), Step(label: "Claimed", mark: claimed || !issue.open ? .done : .todo),
            Step(label: "In a PR", mark: pr == nil ? (issue.open ? .todo : .done) : (pr?.merged == true ? .done : .active)),
            Step(label: "Closed", mark: issue.open ? .todo : .done),
          ], status: status, done: !issue.open,
          stage: !issue.open ? .done : claimed ? .building : .queued,
          badge: !issue.open ? "Closed" : claimed ? "Building" : issue.labels.contains("ready-for-agent") ? "Queued" : "Filed",
          actor: issue.open ? (issue.labels.contains("ready-for-agent") || claimed ? "Issue builder" : "You") : nil,
          when: issue.open && !claimed && issue.labels.contains("ready-for-agent") ? nextRun["loop-issue-queue"] : nil))
    }
    return out.sorted { $0.at > $1.at }
  }

  func refreshGitHub() async {
    async let prs = Shell.exec(
      [
        "gh", "pr", "list", "--state", "all", "--limit", "80", "--json",
        "number,title,url,state,isDraft,mergeable,mergeStateStatus,reviewDecision,headRefName,headRefOid,createdAt,updatedAt,mergedAt,closedAt,statusCheckRollup,body",
      ], in: paths.repo)
    async let iss = Shell.exec(
      [
        "gh", "issue", "list", "--state", "all", "--limit", "80", "--json",
        "number,title,url,state,labels,assignees,createdAt,closedAt",
      ], in: paths.repo)
    let (pc, po) = await prs
    let (ic, io) = await iss
    defer { githubLoaded = true }
    guard pc == 0, ic == 0,
      let p = try? JSONDecoder().decode([PullRequest].self, from: Data(po.utf8)),
      let i = try? JSONDecoder().decode([Issue].self, from: Data(io.utf8))
    else { return }
    pulls = Dictionary(p.map { ($0.number, $0) }, uniquingKeysWith: { a, _ in a })
    issues = Dictionary(i.map { ($0.number, $0) }, uniquingKeysWith: { a, _ in a })
    open = Set(p.filter(\.open).map(\.number) + i.filter(\.open).map(\.number))
    derive()
    reload()
    await refreshNext()
  }

  func merge(_ pr: PullRequest) {
    guard !merging.contains(pr.number) else { return }
    merging.insert(pr.number)
    notice = nil
    Task {
      var cmd = ["gh", "pr", "merge", String(pr.number), "--merge"]
      if let head = pr.headRefOid { cmd += ["--match-head-commit", head] }
      let (code, out) = await Shell.exec(cmd, in: paths.repo)
      merging.remove(pr.number)
      if code == 0 {
        mergedNow.insert(pr.number)
      } else {
        notice = out.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      await refreshGitHub()
    }
  }

  func question(_ item: Item) -> String {
    Store.prompt(from: item.claude) ?? item.asks.map(\.text).joined(separator: "\n")
  }

  func askClaude(_ item: Item, fix: Bool = false) {
    var q = question(item)
    var done: String?
    if fix, let pr = item.pr {
      let state = mergeState(pr)
      let blocker = state.mergeable ? "see its checks and review" : state.title.lowercased()
      q = "Fix PR #\(pr.number) so it can merge: \(blocker).\n\n\(q)"
      done =
        "you have pushed a fix for what blocked PR #\(pr.number) (\(blocker)), and `gh pr view \(pr.number) --json mergeable,statusCheckRollup` run after that push shows it MERGEABLE with every check passed"
    }
    ask(q, loop: item.loops.first, from: item.id, done: done)
  }

  func reply(_ item: Item, _ answer: String) {
    let asked = question(item)
    ask("\(asked)\n\nMy answer: \(answer)", loop: item.loops.first, from: item.id) { ok in
      if ok { self.recordAnswer(loop: item.loops.first, task: item.headline, question: asked, answer: answer, source: "brief") }
    }
  }

  func hide(_ item: Item, undo: UndoManager? = nil) {
    for a in item.asks { dismiss(a) }
    items.removeAll { $0.id == item.id }
    undo?.registerUndo(withTarget: self) { store in
      MainActor.assumeIsolated { store.unhide(item) }
    }
    undo?.setActionName("Hide")
  }

  func unhide(_ item: Item) {
    restore(item.asks.map(\.id))
    reload()
  }

  private func commits(since sha: String?, path: String? = nil) async -> [String] {
    guard let sha else { return [] }
    var cmd = ["git", "log", "--format=%s", "\(sha)..origin/main"]
    if let path { cmd += ["--", path] }
    let (code, out) = await Shell.exec(cmd, in: paths.repo)
    return code == 0 ? out.split(separator: "\n").map(String.init) : []
  }

  private func counted(_ n: Int, _ one: String, _ many: String) -> String { n == 1 ? "1 \(one)" : "\(n) \(many)" }

  private func hints(_ loop: String) -> [String] {
    guard let b = latest[loop] else { return [] }
    return Briefs.body(b).split(separator: "\n")
      .flatMap { Briefs.sentences($0.hasPrefix("- ") ? String($0.dropFirst(2)) : String($0)) }
      .filter { s in ["next run", "left for later"].contains { s.lowercased().contains($0) } }
      .map { capitalizedFirst($0) }
  }

  func refreshNext() async {
    var out: [String: [String]] = [:]
    for l in specs { out[l.name] = await next(l) }
    nextUp = out
  }

  private func next(_ l: LoopSpec) async -> [String] {
    let state = states[l.name]
    let sha = state?.sha
    let since = state?.at.map { Clock.day($0, now: now) } ?? "its first run"
    var lines: [String] = []
    switch l.name {
    case "loop-issue-queue":
      let building = Set(pulls.values.filter(\.open).compactMap(\.issue))
      let frontier = issues.values
        .filter { $0.open && $0.labels.contains("ready-for-agent") && $0.assignees.isEmpty && !building.contains($0.number) }
        .sorted { $0.number < $1.number }
      if let first = frontier.first {
        lines.append("Builds #\(first.number): \(capitalizedFirst(first.title))")
        if frontier.count > 1 { lines.append("Then \(frontier.dropFirst().prefix(3).map { "#\($0.number)" }.joined(separator: ", "))") }
      } else {
        let ready = issues.values.filter { $0.open && $0.labels.contains("ready-for-agent") }.count
        lines.append(
          ready == 0
            ? "No ready-for-agent issue is open"
            : "All \(ready) ready-for-agent issues are claimed or already in a PR, so it waits for a new one")
      }
    case "loop-pr-review":
      let reviewed = reviewed
      let fresh = pulls.values.filter { $0.open && reviewed[String($0.number)] != $0.headRefOid }.sorted { $0.number < $1.number }
      lines.append(
        fresh.isEmpty
          ? "Every open PR is reviewed at its latest commit"
          : "Reviews \(fresh.map { "#\($0.number)" }.joined(separator: ", ")): new commits since its last look")
    case "loop-pr-fix":
      let red = pulls.values.filter { $0.open && $0.loop != nil && $0.checks.failed > 0 }.sorted { $0.number < $1.number }
      let actOn = pulls.values.filter { $0.open && $0.loop != nil && (verdicts[$0.number] ?? "").lowercased().contains("act on") }
      if red.isEmpty && actOn.isEmpty { lines.append("No loop PR has red checks or review items to fix") }
      for pr in red { lines.append("Fixes #\(pr.number): \(counted(pr.checks.failed, "check", "checks")) failing") }
      for pr in actOn where !red.contains(pr) { lines.append("Works through the review's Act on items on #\(pr.number)") }
    case "loop-green-main":
      let c = await commits(since: sha)
      lines.append(c.isEmpty ? "Main has not moved since \(since); it re-checks CI" : "Checks \(counted(c.count, "new commit", "new commits")) on main")
    case "loop-convex-review":
      let c = await commits(since: sha, path: "convex")
      lines.append(c.isEmpty ? "No Convex change on main since \(since)" : "Reviews \(counted(c.count, "commit", "commits")) that changed convex/")
    case "loop-tests":
      let c = await commits(since: sha)
      let gaps = (state?.raw["gaps"] as? [Any])?.count ?? 0
      lines.append(c.isEmpty ? "No behaviour change merged since \(since)" : "Probes \(counted(c.count, "merged commit", "merged commits")) for changes no test catches")
      if gaps > 0 { lines.append("\(counted(gaps, "weak test", "weak tests")) still on its list") }
    case "loop-prod-errors":
      lines.append("Production errors since \(since), inside \(l.window ?? "its hours")")
    case "loop-convex-cost":
      let drivers = (state?.raw["drivers"] as? [[String: Any]])?.compactMap { $0["function"] as? String } ?? []
      lines.append(drivers.isEmpty ? "This week's Convex spend drivers" : "Re-measures \(joined(drivers))")
    case "loop-parked-branches":
      let (code, out) = await Shell.exec(["git", "branch", "-r", "--list", "origin/wip/*"], in: paths.repo)
      let names = code == 0 ? out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "origin/", with: "") } : []
      lines.append(names.isEmpty ? "No parked wip/ branches" : "Measures drift on \(joined(names))")
    case "loop-dep-drift":
      lines.append("Advisories and dependency releases since \(since)")
    case "loop-correct":
      lines.append("Mistakes agents repeated since \(since)")
    default:
      if let ships = l.ships { lines.append(capitalizedFirst(ships)) }
    }
    return lines + hints(l.name)
  }

  var repoSlug: String? {
    guard let config = Reader.text(paths.common.appending(path: "config")) else { return nil }
    return Reader.groups(#"github\.com[:/]([\w.-]+/[\w.-]+?)(?:\.git)?\s"#, in: config + "\n").first
  }
}
