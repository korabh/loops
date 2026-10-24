import Foundation
import Observation
import SwiftUI

struct GoalIdea: Identifiable, Codable, Equatable {
  enum Source: String, Codable {
    case spend, conflict, retry, chore, claude
  }

  let id: String
  let source: Source
  let title: String
  let task: String
  let done: String
  let why: String
  var loop: String?
  var key: String?
  var turns: Int?
  var match: String?
  var summary: String?

  var symbol: String {
    switch source {
    case .spend: "leaf"
    case .conflict: "arrow.trianglehead.branch"
    case .retry: "arrow.clockwise"
    case .chore: "checklist"
    case .claude: Symbols.askClaude
    }
  }

  var origin: String {
    switch source {
    case .spend: "Spend"
    case .conflict: "GitHub"
    case .retry: "Fell short"
    case .chore: "Check"
    case .claude: "Claude"
    }
  }

  var launchKey: String { key ?? "idea:\(id)" }

  static func chores(_ gate: [ProjectConfig.GateStep]) -> [GoalIdea] {
    gate.map { step in
      let command = step.run.replacingOccurrences(of: "\"$BASE\"", with: "origin/main").replacingOccurrences(of: "$BASE", with: "origin/main")
      return GoalIdea(
        id: "gate-\(step.name)", source: .chore, title: "\(capitalizedFirst(step.name)) green",
        task: "Make the \(step.name) step of the loop gate pass on a branch off origin/main. Fix the cause of a failure rather than skipping it.",
        done:
          "\(command) exits 0 on that branch with its output printed in the final message, and any change is in an open pull request whose URL is in the final message",
        why: "Every loop runs it before it pushes.", match: step.name)
    }
  }
}

@MainActor @Observable
final class GoalDraft {
  static let shared = GoalDraft()

  var task = ""
  var done = ""
  var turns = Goal.turns
  var key: String?
  var loop: String?
  var focus = 0

  func fill(_ idea: GoalIdea) {
    task = idea.task
    done = idea.done
    turns = idea.turns ?? Goal.turns
    key = idea.launchKey
    loop = idea.loop
    focus += 1
  }

  func clear() {
    task = ""
    done = ""
    turns = Goal.turns
    key = nil
    loop = nil
  }
}

@MainActor @Observable
final class GoalIdeas {
  static let shared = GoalIdeas()

  private(set) var claude: [GoalIdea] = []
  private(set) var at: Date?
  private(set) var busy = false
  private(set) var usage: Usage?
  private(set) var drafts = Usage()
  private(set) var failure: String?
  private(set) var dismissed: Set<String> = []
  private(set) var dones: [String: String] = [:]
  private(set) var writing: String?

  private static let ideasKey = "goalIdeas"
  private static let atKey = "goalIdeasAt"
  private static let dismissedKey = "dismissedGoalIdeas"
  private static let usageKey = "goalIdeasUsage"

  private static let ideasSchema =
    #"{"type":"object","additionalProperties":false,"required":["ideas"],"properties":{"ideas":{"type":"array","maxItems":4,"items":{"type":"object","additionalProperties":false,"required":["title","task","done","why"],"properties":{"title":{"type":"string"},"task":{"type":"string"},"done":{"type":"string"},"why":{"type":"string"}}}}}}"#

  private static let doneSchema =
    #"{"type":"object","additionalProperties":false,"required":["done"],"properties":{"done":{"type":"string"}}}"#

  private static let rules =
    "A done condition is one sentence a separate judge can check from the conversation alone: name a command that must exit 0 with its output printed, or a number Claude must print in its final message. When the work changes code, end it with: and the change is in an open pull request whose URL is in the final message. Commands run from the repo root; never name an absolute path. No 'Done when' prefix and no turn cap; the app adds the cap."

  private init() {
    let d = UserDefaults.standard
    if let data = d.data(forKey: Self.ideasKey), let list = try? JSONDecoder().decode([GoalIdea].self, from: data) { claude = list }
    at = d.object(forKey: Self.atKey) as? Date
    dismissed = Set(d.stringArray(forKey: Self.dismissedKey) ?? [])
    usage = d.data(forKey: Self.usageKey).flatMap { try? JSONDecoder().decode(Usage.self, from: $0) }
  }


  func dismiss(_ idea: GoalIdea) {
    dismissed.insert(idea.id)
    UserDefaults.standard.set(Array(dismissed), forKey: Self.dismissedKey)
  }

  func restore() {
    dismissed = []
    UserDefaults.standard.removeObject(forKey: Self.dismissedKey)
  }

  func ask(store: Store) async {
    guard !busy else { return }
    busy = true
    failure = nil
    defer { busy = false }
    let prompt = """
      Suggest up to four goals for Claude Code's /goal in this repo. \(store.project?.about ?? "") A goal is an outcome Claude works toward in the background until a separate model judges it met, so pick work that is worth doing now given the state below, that one session can finish, and that differs from the goals already set. For each give a title of two to five words, a task of one or two sentences saying what to do, a done condition, and why: one short line naming the signal below that points to it. \(Self.rules)

      \(store.goalContext)
      """
    guard let obj = await run(prompt, model: "sonnet", schema: Self.ideasSchema, store: store) else { return }
    let used = Usage(result: obj)
    let list = ((obj["structured_output"] as? [String: Any])?["ideas"] as? [[String: Any]]) ?? []
    let ideas = list.compactMap { d -> GoalIdea? in
      guard let title = d["title"] as? String, let task = d["task"] as? String, let done = d["done"] as? String else { return nil }
      return GoalIdea(
        id: "claude-\(abs(task.hashValue))", source: .claude, title: title, task: task,
        done: Self.condition(done), why: d["why"] as? String ?? "")
    }
    guard !ideas.isEmpty else {
      failure = "Claude Code returned no ideas."
      return
    }
    claude = ideas
    at = Date()
    usage = used
    let d = UserDefaults.standard
    d.set(try? JSONEncoder().encode(used), forKey: Self.usageKey)
    d.set(try? JSONEncoder().encode(ideas), forKey: Self.ideasKey)
    d.set(at, forKey: Self.atKey)
  }

  func suggestDone(for task: String, store: Store) async {
    let task = task.trimmingCharacters(in: .whitespacesAndNewlines)
    guard dones[task] == nil, writing != task else { return }
    writing = task
    defer { if writing == task { writing = nil } }
    let prompt = "Someone is setting a /goal for Claude Code in this repo. \(store.project?.about ?? "")\n\nTheir task: \(task)\n\nWrite its done condition. \(Self.rules)"
    guard let obj = await run(prompt, model: "haiku", schema: Self.doneSchema, store: store),
      let done = (obj["structured_output"] as? [String: Any])?["done"] as? String
    else { return }
    drafts = drafts + Usage(result: obj)
    dones[task] = Self.condition(done)
  }

  private static func condition(_ s: String) -> String {
    var s = s.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
    if s.lowercased().hasPrefix("done when ") { s = String(s.dropFirst(10)) }
    return s
  }

  private func run(_ prompt: String, model: String, schema: String, store: Store) async -> [String: Any]? {
    let (_, out) = await Shell.exec(
      [
        "claude", "-p", "--model", model, "--effort", "low", "--tools", "", "--no-session-persistence", "--disable-slash-commands",
        "--output-format", "json", "--json-schema", schema, prompt,
      ], in: store.paths.repo, config: store.config)
    let json = out.split(separator: "\n").last { $0.hasPrefix("{") }.map(String.init) ?? ""
    guard let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else {
      failure = out.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init) ?? "Claude Code returned nothing."
      return nil
    }
    return obj
  }
}

extension Store {
  private var recentGoals: [BgTask] { tasks.filter { $0.goal != nil && now.timeIntervalSince($0.started) < 7 * 86400 } }

  static func prs(in text: String) -> [Int] {
    guard let re = try? Regex(#"#(\d+)"#) else { return [] }
    return text.matches(of: re).compactMap { $0.output[1].substring.flatMap { Int($0) } }
  }

  static func names(_ pr: Int, in text: String) -> Bool {
    (try? Regex("(?i)(#|\\bpr[-_/ ]?|pull[-_ ]request[-_ ]#?)\(pr)(?![0-9])")).map { text.contains($0) } ?? false
  }

  private func working(on pr: Int) -> Bool {
    let jobs = jobs.jobs.values.filter { ["working", "blocked"].contains($0.state) }.map(\.name)
    let mine = tasks.filter(\.active).map { "\($0.title) \($0.prompt)" }
    return (jobs + mine).contains { Self.names(pr, in: $0) }
  }

  private func taken(_ idea: GoalIdea) -> Bool {
    if Self.prs(in: idea.title + " " + idea.task).contains(where: working(on:)) { return true }
    if recentGoals.contains(where: { $0.key == idea.launchKey }) || task(key: idea.launchKey) != nil && idea.source != .chore { return true }
    guard let match = idea.match else { return false }
    return recentGoals.contains { ($0.title + " " + $0.prompt + " " + ($0.goal?.done ?? "")).localizedCaseInsensitiveContains(match) }
  }

  var goalIdeas: [GoalIdea] {
    var spend: [GoalIdea] = []
    var out: [GoalIdea] = []
    let found = (fixedAdvice.map { [$0] } ?? []) + specs.flatMap { advice($0.name) }
    for a in found.sorted(by: { ($0.saving ?? 0) > ($1.saving ?? 0) }).filter({ if case .ask(_, _, _?)? = $0.action { true } else { false } }).prefix(2) {
      guard case .ask(let label, let prompt, let done?)? = a.action else { continue }
      let verb = label.replacingOccurrences(of: "Ask Claude to ", with: "")
      spend.append(
        GoalIdea(
          id: "spend-\(a.id)", source: .spend, title: "\(a.loop.map(title) ?? "Loops"): \(verb)", task: prompt, done: done,
          why: "\(a.title) · \(a.label)", loop: a.loop, key: "advice:\(a.id)", summary: a.detail))
    }
    for pr in pulls.values.filter({ $0.open && !$0.isDraft && $0.mergeStateStatus == "DIRTY" }).sorted(by: { $0.number > $1.number }).prefix(2) {
      out.append(
        GoalIdea(
          id: "conflict-\(pr.number)", source: .conflict, title: "Unblock PR #\(pr.number)",
          task: "Bring pull request #\(pr.number) (\(pr.title)) up to date with main and resolve its conflicts, keeping the intent of both sides.",
          done:
            "gh pr view \(pr.number) --json mergeable prints MERGEABLE, bun run test passes on its branch with the summary printed in the final message, and the resolution is pushed to the pull request",
          why: "It has merge conflicts with main.", turns: 10))
    }
    for t in recentGoals.filter({ !$0.active && !$0.goalMet && $0.limit == nil }).prefix(2) {
      guard let goal = t.goal, !recentGoals.contains(where: { $0.prompt == t.prompt && $0.started > t.started }) else { continue }
      out.append(
        GoalIdea(
          id: "retry-\(t.id)", source: .retry, title: "Try again: \(t.title.replacingOccurrences(of: "Goal: ", with: ""))", task: t.prompt,
          done: goal.done, why: goal.reason.map { "Ended: \($0)" } ?? "It ended before the goal was met.", loop: t.loop,
          turns: min(60, goal.turns * 2)))
    }
    out += GoalIdeas.shared.claude + spend + GoalIdea.chores(project?.gate ?? [])
    let dismissed = GoalIdeas.shared.dismissed
    var seen = Set<String>()
    return out.filter { !dismissed.contains($0.id) && !taken($0) && seen.insert($0.id).inserted }
  }

  func start(_ idea: GoalIdea, task: String? = nil, done: String? = nil, turns: Int? = nil) {
    let task = task ?? idea.task
    let done = done ?? idea.done
    if idea.source == .spend, let key = idea.key {
      ask(task, loop: idea.loop, from: key, done: done)
    } else {
      setGoal(task, done: done, turns: turns ?? idea.turns ?? Goal.turns, key: idea.launchKey)
    }
  }

  var goalContext: String {
    var lines: [String] = []
    let ready = issues.values.filter(\.open).sorted { $0.number > $1.number }.prefix(15)
    if !ready.isEmpty {
      lines.append("Open issues:")
      lines += ready.map { "- #\($0.number) \($0.title)\($0.labels.isEmpty ? "" : " [\($0.labels.joined(separator: ", "))]")" }
    }
    let prs = pulls.values.filter(\.open).sorted { $0.number > $1.number }.prefix(12)
    if !prs.isEmpty {
      lines.append("Open pull requests:")
      lines += prs.map { pr in
        let state = pr.mergeStateStatus == "DIRTY" ? "conflicts" : pr.checks.failing.isEmpty ? "checks pass" : "failing \(pr.checks.failing.joined(separator: ", "))"
        return "- #\(pr.number) \(pr.title) (\(state))"
      }
    }
    let latest = briefs.suffix(12)
    if !latest.isEmpty {
      lines.append("Latest loop results:")
      lines += latest.map { "- \(title($0.loop)): \(Briefs.readable(Briefs.sentences(Briefs.body($0)).first ?? $0.text).prefix(220))" }
    }
    let costly = topAdvice.prefix(4)
    if !costly.isEmpty {
      lines.append("Where the loops spend most:")
      lines += costly.map { "- \($0.loop.map(title) ?? "Loops"): \($0.title)" }
    }
    let goals = tasks.filter { $0.goal != nil }.prefix(8)
    if !goals.isEmpty {
      lines.append("Goals already set:")
      lines += goals.map { "- \($0.title.replacingOccurrences(of: "Goal: ", with: "")): \($0.label)" }
    }
    return lines.joined(separator: "\n")
  }
}
