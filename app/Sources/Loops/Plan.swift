import Foundation
import Observation
import SwiftUI

struct Round: Codable, Equatable {
  struct Question: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let question: String
    var options: [String]?
    let recommended: String
    var why: String?
  }

  let settled: String
  let questions: [Question]
  let done: Bool
  var issue: String?
  var chart: String?
}

struct Proposal: Codable, Equatable {
  var idea: String
  var session: String?
  var rounds: [Round] = []
  var answers: [String: String] = [:]
  var cost = 0.0
  var tokens: Int?
  var target: Int?
  var issue: String?
  var started = Date()
  var waiting: Waiting?

  struct Waiting: Codable, Equatable {
    let message: String
    let effort: String
    let label: String
    let limit: String
    let until: Date
  }

  var current: Round? { rounds.last }
}

struct FeatureIdea: Codable, Equatable, Identifiable {
  let title: String
  let pitch: String
  let why: String

  var id: String { title }
}

@MainActor @Observable
final class Planner {

  private(set) var proposal: Proposal?
  private(set) var busy: String?
  private(set) var since: Date?
  private(set) var failure: String?
  private(set) var ideas: [FeatureIdea] = []
  private(set) var ideasAt: Date?
  private(set) var ideasUsage: Usage?
  private(set) var suggesting = false
  private(set) var ideasFailure: String?

  private static let key = "proposal"
  private static let ideasKey = "featureIdeas"
  private static let ideasAtKey = "featureIdeasAt"
  private static let ideasUsageKey = "featureIdeasUsage"

  private static let ideasSchema =
    #"{"type":"object","additionalProperties":false,"required":["ideas"],"properties":{"ideas":{"type":"array","maxItems":5,"items":{"type":"object","additionalProperties":false,"required":["title","pitch","why"],"properties":{"title":{"type":"string"},"pitch":{"type":"string"},"why":{"type":"string"}}}}}}"#

  private static let suggestApp =
    "You are running /propose with no idea inside the Loops app, so this run only suggests. Return the suggestions through the structured output: `title` of three to six words, `pitch` of one or two sentences, and `why`: one short line naming the signal in the repo that points to it. Change nothing in the repo."

  private static let schema = #"""
    {"type":"object","additionalProperties":false,"required":["settled","questions","done"],"properties":{
     "settled":{"type":"string"},
     "questions":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["id","title","question","recommended"],"properties":{
       "id":{"type":"string"},"title":{"type":"string"},"question":{"type":"string"},
       "options":{"type":"array","items":{"type":"string"}},"recommended":{"type":"string"},"why":{"type":"string"}}}},
     "done":{"type":"boolean"},
     "issue":{"type":"string"},
     "chart":{"type":"string"}}}
    """#

  private static let app =
    "You are running /propose inside the Loops app. The app shows each round as a form and sends the person's answers back as the next message. Return every reply through the structured output: `questions` is this round's frontier, each with an id (q1, q2, …), a short title, the question, its choices when it has some, your recommended answer and a one-line why; `settled` is a short summary of what is decided so far. Once the frontier is empty, leave `questions` empty and set `done`. Publish only when the person's message is exactly \"publish\", then put the issue URL in `issue`. Put the current draft statechart's Mermaid source in `chart` whenever the round asks the person to agree to it or it changed since the last round."

  private static func sharpen(_ n: Int) -> String {
    " This proposal sharpens issue #\(n), which already exists: read it with gh issue view \(n) --comments as the idea. Publish by replacing that issue's body with the spec and adding the ready-for-agent label, not by opening a new issue, then put its URL in `issue`."
  }

  @ObservationIgnored private let defaults: UserDefaults

  init(defaults: UserDefaults) {
    self.defaults = defaults
    let d = defaults
    if let data = d.data(forKey: Self.key), let p = try? JSONDecoder().decode(Proposal.self, from: data) {
      proposal = p
    }
    if let data = d.data(forKey: Self.ideasKey), let list = try? JSONDecoder().decode([FeatureIdea].self, from: data) { ideas = list }
    ideasAt = d.object(forKey: Self.ideasAtKey) as? Date
    ideasUsage = d.data(forKey: Self.ideasUsageKey).flatMap { try? JSONDecoder().decode(Usage.self, from: $0) }
  }

  func suggest(store: Store) {
    guard !suggesting else { return }
    suggesting = true
    ideasFailure = nil
    let home = Self.home(store.paths)
    let command = [
      "claude", "-p", "--output-format", "json", "--json-schema", Self.ideasSchema, "--effort", "low", "--permission-mode", "auto",
      "--no-session-persistence", "--append-system-prompt", Self.suggestApp, "/propose",
    ]
    Task {
      let (_, out) = await Shell.exec(command, in: home, config: store.config)
      suggesting = false
      let json = out.split(separator: "\n").last { $0.hasPrefix("{") }.map(String.init) ?? ""
      guard let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else {
        ideasFailure = out.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init) ?? "Claude Code returned nothing."
        return
      }
      let used = Usage(result: obj)
      guard let s = obj["structured_output"], let data = try? JSONSerialization.data(withJSONObject: s),
        let list = (try? JSONDecoder().decode([String: [FeatureIdea]].self, from: data))?["ideas"], !list.isEmpty
      else {
        ideasFailure = (obj["result"] as? String).map { String($0.prefix(300)) } ?? "Claude Code returned no ideas."
        return
      }
      ideas = list
      ideasAt = Date()
      ideasUsage = used
      defaults.set(try? JSONEncoder().encode(used), forKey: Self.ideasUsageKey)
      defaults.set(try? JSONEncoder().encode(list), forKey: Self.ideasKey)
      defaults.set(ideasAt, forKey: Self.ideasAtKey)
    }
  }

  func explore(_ idea: FeatureIdea, store: Store) {
    start("\(idea.title): \(idea.pitch)", store: store)
  }

  private func save() {
    if let proposal, let data = try? JSONEncoder().encode(proposal) {
      defaults.set(data, forKey: Self.key)
    } else {
      defaults.removeObject(forKey: Self.key)
    }
  }

  func answer(_ id: String) -> Binding<String> {
    Binding(
      get: { self.proposal?.answers[id] ?? "" },
      set: {
        self.proposal?.answers[id] = $0
        self.save()
      })
  }

  func start(_ idea: String, target: Int? = nil, store: Store) {
    let idea = idea.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !idea.isEmpty else { return }
    var p = Proposal(idea: idea)
    p.target = target
    proposal = p
    save()
    store.page = .plan
    step("/propose \(idea)", effort: "low", label: "Reading the code", store: store)
  }

  func send(store: Store) {
    guard let p = proposal, let round = p.current else { return }
    let lines = round.questions.map { q in
      let a = (p.answers[q.id] ?? q.recommended).trimmingCharacters(in: .whitespacesAndNewlines)
      return "\(q.id) (\(q.title)): \(a.isEmpty ? q.recommended : a)"
    }
    step(lines.joined(separator: "\n"), effort: "low", label: "Thinking about your answers", store: store)
  }

  func more(store: Store) {
    step("Keep going: ask about anything still unsettled.", effort: "low", label: "Looking for open questions", store: store)
  }

  func publish(store: Store) {
    step("publish", effort: "medium", label: "Writing and publishing the spec", store: store)
  }

  func reset() {
    proposal = nil
    failure = nil
    save()
  }

  static func paused(_ obj: [String: Any]?, out: String, now: Date) -> (limit: String, until: Date)? {
    let text = (obj?["result"] as? String) ?? out
    guard obj == nil || obj?["is_error"] as? Bool == true, UsageLimit.reached(text) else { return nil }
    let line = text.split(separator: "\n").first { UsageLimit.reached(String($0)) }.map(String.init) ?? text
    return (line.trimmingCharacters(in: .whitespaces), UsageLimit.resets(in: text, after: now) ?? now.addingTimeInterval(3600))
  }

  func wake(store: Store) {
    guard busy == nil, let w = proposal?.waiting, Date() >= w.until else { return }
    step(w.message, effort: w.effort, label: w.label, store: store)
  }

  func sendNow(store: Store) {
    guard let w = proposal?.waiting else { return }
    step(w.message, effort: w.effort, label: w.label, store: store)
  }

  func stopWaiting() {
    proposal?.waiting = nil
    save()
  }

  private func step(_ message: String, effort: String, label: String, store: Store) {
    guard busy == nil, var p = proposal else { return }
    p.waiting = nil
    proposal = p
    save()
    busy = label
    since = Date()
    failure = nil
    let home = Self.home(store.paths)
    let config = store.runner?.account ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude").path
    let command =
      ["claude", "-p"] + (p.session.map { ["--resume", $0] } ?? [])
      + [
        "--output-format", "json", "--json-schema", Self.schema, "--effort", effort, "--permission-mode", "auto",
        "--append-system-prompt", Self.app + (p.target.map { Self.sharpen($0) } ?? ""), message,
      ]
    Task {
      let (_, out) = await Shell.exec(command, in: home, config: config)
      busy = nil
      let json = out.split(separator: "\n").last { $0.hasPrefix("{") }.map(String.init) ?? ""
      let parsed = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
      if let hit = Self.paused(parsed, out: out, now: Date()) {
        p.waiting = .init(message: message, effort: effort, label: label, limit: hit.limit, until: hit.until)
        proposal = p
        save()
        return
      }
      guard let obj = parsed else {
        failure = out.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init) ?? "Claude Code returned nothing."
        return
      }
      p.session = obj["session_id"] as? String ?? p.session
      let used = Usage(result: obj)
      p.cost += used.cost
      p.tokens = (p.tokens ?? 0) + used.tokens
      if let s = obj["structured_output"], let data = try? JSONSerialization.data(withJSONObject: s),
        let round = try? JSONDecoder().decode(Round.self, from: data)
      {
        p.rounds.append(round)
        p.answers = Dictionary(uniqueKeysWithValues: round.questions.map { ($0.id, $0.recommended) })
        if let issue = round.issue, !issue.isEmpty { p.issue = issue }
      } else {
        failure = (obj["result"] as? String).map { String($0.prefix(300)) } ?? "Claude Code returned no round."
      }
      proposal = p
      save()
      if p.issue != nil { await store.refreshGitHub() }
    }
  }

  static func home(_ paths: Paths) -> URL {
    let fm = FileManager.default
    let trees = ((try? fm.contentsOfDirectory(at: paths.repo.appending(path: ".claude/worktrees"), includingPropertiesForKeys: nil)) ?? [])
    return ([paths.repo] + trees).first { fm.fileExists(atPath: $0.appending(path: ".claude/skills/propose/SKILL.md").path) } ?? paths.repo
  }
}
