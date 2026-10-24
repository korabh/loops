import Foundation
import Observation

struct RecallBrief: Codable, Equatable {
  struct Thread: Codable, Equatable, Identifiable {
    let status: String
    let title: String
    var pr: Int?
    var branch: String?

    var id: String { "\(status)|\(pr.map(String.init) ?? branch ?? title)" }
  }

  struct Problem: Codable, Equatable, Identifiable {
    let text: String
    var pr: Int?

    var id: String { text }
  }

  struct Next: Codable, Equatable {
    let text: String
    var pr: Int?
    var prompt: String?
  }

  let capsule: [String]
  let threads: [Thread]
  let problems: [Problem]
  let next: Next
  var at = Date()
  var hours = 24
  var topic: String?

  private enum CodingKeys: String, CodingKey { case capsule, threads, problems, next, at, hours, topic }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    capsule = try c.decode([String].self, forKey: .capsule)
    threads = try c.decode([Thread].self, forKey: .threads)
    problems = try c.decode([Problem].self, forKey: .problems)
    next = try c.decode(Next.self, forKey: .next)
    at = (try? c.decode(Date.self, forKey: .at)) ?? Date()
    hours = (try? c.decode(Int.self, forKey: .hours)) ?? 24
    topic = try? c.decode(String.self, forKey: .topic)
  }

  var window: String {
    let span = hours < 48 ? "last \(hours)h" : "last \(hours / 24) days"
    return topic.map { "\(span) · \($0)" } ?? span
  }
}

enum RecallScope: String, CaseIterable, Identifiable {
  case away, day, week

  var id: String { rawValue }

  var title: String {
    switch self {
    case .away: "Since last time"
    case .day: "Today"
    case .week: "This week"
    }
  }

  func hours(since last: Date?, now: Date) -> Int {
    switch self {
    case .away: last.map { min(168, max(1, Int(now.timeIntervalSince($0) / 3600) + 1)) } ?? 24
    case .day: 24
    case .week: 168
    }
  }
}

@MainActor @Observable
final class Recall {
  private(set) var brief: RecallBrief?
  private(set) var started: Date?
  var failure: String?

  var running: Bool { started != nil }

  private static let skill = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/skills/recall")

  private static let schema =
    #"{"type":"object","additionalProperties":false,"required":["capsule","threads","problems","next"],"properties":{"capsule":{"type":"array","maxItems":5,"items":{"type":"string"}},"threads":{"type":"array","maxItems":20,"items":{"type":"object","additionalProperties":false,"required":["status","title"],"properties":{"status":{"type":"string","enum":["merged","open","inflight","verified","reverted","planned"]},"title":{"type":"string"},"pr":{"type":"integer"},"branch":{"type":"string"}}}},"problems":{"type":"array","maxItems":5,"items":{"type":"object","additionalProperties":false,"required":["text"],"properties":{"text":{"type":"string"},"pr":{"type":"integer"}}}},"next":{"type":"object","additionalProperties":false,"required":["text"],"properties":{"text":{"type":"string"},"pr":{"type":"integer"},"prompt":{"type":"string"}}}}}"#

  @ObservationIgnored private let defaults: UserDefaults

  init(defaults: UserDefaults) {
    self.defaults = defaults
    if let data = defaults.data(forKey: "recall"), let saved = try? JSONDecoder().decode(RecallBrief.self, from: data) {
      brief = saved
    }
  }

  func run(_ scope: RecallScope, topic: String, store: Store) {
    guard !running else { return }
    let hours = scope.hours(since: brief?.at, now: Date())
    let topic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
    let projects = store.configs.map { URL(fileURLWithPath: $0).appending(path: "projects").path }
    let prompt = Self.prompt(hours: hours, topic: topic.isEmpty ? nil : topic, projects: projects, repo: store.paths.repo, store: store)
    started = Date()
    failure = nil
    Task {
      let (_, out) = await Shell.exec(
        [
          "claude", "-p", prompt, "--model", "sonnet", "--output-format", "json", "--json-schema", Self.schema,
          "--permission-mode", "dontAsk", "--max-budget-usd", "3", "--disallowedTools", "Edit,Write,NotebookEdit",
          "--allowedTools",
          "Read,Grep,Glob,Agent,Bash(ls *),Bash(grep *),Bash(head *),Bash(tail *),Bash(wc *),Bash(jq *),Bash(gh pr list *),Bash(gh pr view *),Bash(gh pr checks *),Bash(gh run list *),Bash(gh issue list *),Bash(gh issue view *),Bash(git log *),Bash(git branch *),Bash(git worktree list *)",
          "--add-dir",
        ] + projects + [Self.skill.path], in: store.paths.repo, config: store.config)
      started = nil
      let json = out.split(separator: "\n").last { $0.hasPrefix("{") }.map(String.init) ?? ""
      let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
      guard let structured = obj?["structured_output"],
        let data = try? JSONSerialization.data(withJSONObject: structured),
        var b = try? JSONDecoder().decode(RecallBrief.self, from: data)
      else {
        let why = (obj?["subtype"] as? String).map { $0 == "error_max_budget_usd" ? "it reached its $3 cap" : $0 } ?? String(out.suffix(300))
        failure = "The catch-up came back empty: \(why)."
        return
      }
      b.at = Date()
      b.hours = hours
      b.topic = topic.isEmpty ? nil : topic
      brief = b
      if let data = try? JSONEncoder().encode(b) { defaults.set(data, forKey: "recall") }
    }
  }

  private static func prompt(hours: Int, topic: String?, projects: [String], repo: URL, store: Store) -> String {
    let slug = Spend.slug(repo.path)
    let since = Date().addingTimeInterval(-Double(hours) * 3600)
    let briefs = store.briefs.filter { $0.at >= since }.suffix(30).map { "- \($0.at.ISO8601Format()) \($0.loop): \($0.text.prefix(300))" }
    let tasks = store.tasks.filter { $0.started >= since }.prefix(20).map { t in
      "- \(t.title) · \(t.label)\(t.answer.map { " · \($0.prefix(200))" } ?? "")"
    }
    return """
      Read \(skill.path)/SKILL.md and follow it to catch me up. This Mac differs from what it assumes:

      - Scope: the last \(hours) hours, \(topic.map { "on \($0)" } ?? "every thread, no topic named"), in this repo only.
      - Transcripts are Claude Code's, not Cursor's: `<projects>/<slug>/<session>.jsonl` for every slug starting with `\(slug)` (the repo and its worktrees), under \(projects.joined(separator: " and ")). Skip every `subagents/` folder and sessions that ran `claude -p`. Order by modification time and grep for the topic before reading.
      - Read the structured record first, since it is exact and cheap: `gh pr list --state all --limit 60 --json number,title,state,headRefName,createdAt,mergedAt`, `git worktree list`, `git branch -r --sort=-committerdate`, `gh run list --limit 30`, and the loop briefs and app tasks below. Read transcripts for what those leave open: decisions, work that never reached a PR, and two sessions working on the same thing.
      - You only read. Change nothing.

      Return the brief as structured output: `capsule` (at most 5), `threads` (each with `status` merged, open, inflight, verified, reverted or planned, and its `pr` or `branch` when known), `problems` (at most 5, recurring ones, with a `pr` when one is the place to act), and `next` (the single most useful move, with `pr` when it is a PR and `prompt`, a self-contained instruction a Claude Code session could start from, when it is work).

      Loop briefs in the window:
      \(briefs.isEmpty ? "(none)" : briefs.joined(separator: "\n"))

      Tasks started from the Loops app in the window:
      \(tasks.isEmpty ? "(none)" : tasks.joined(separator: "\n"))
      """
  }
}
