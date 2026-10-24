import Foundation
import Observation

struct SkillHealth: Decodable, Equatable {
  struct Summary: Decodable, Equatable {
    let runs: Int
    let pushback: Int
    let interrupts: Int
    let lessons: Int
    let problems: Int
  }

  struct Run: Decodable, Equatable, Identifiable {
    let at: String
    let how: String
    let file: String
    let line: Int
    let pushback: Bool
    let interrupted: Bool
    let said: [String]

    enum Key: String, CodingKey { case at, how, file, line, pushback, interrupted, said }

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: Key.self)
      at = (try? c.decode(String.self, forKey: .at)) ?? ""
      how = (try? c.decode(String.self, forKey: .how)) ?? "read"
      file = (try? c.decode(String.self, forKey: .file)) ?? ""
      line = (try? c.decode(Int.self, forKey: .line)) ?? 0
      pushback = (try? c.decode(Bool.self, forKey: .pushback)) ?? false
      interrupted = (try? c.decode(Bool.self, forKey: .interrupted)) ?? false
      said = (try? c.decode([String].self, forKey: .said)) ?? []
    }

    var id: String { "\(file):\(line)" }
    var date: Date? { Reader.date(at) }
    var flagged: Bool { pushback || interrupted }
  }

  let skill: String
  let summary: Summary
  let problems: [String]
  let runs: [Run]
  let lessons: [String]
  let report: String
  let retro: RetroReport?

  enum Key: String, CodingKey { case skill, summary, problems, runs, lessons, report, retro }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: Key.self)
    skill = try c.decode(String.self, forKey: .skill)
    summary = (try? c.decode(Summary.self, forKey: .summary)) ?? Summary(runs: 0, pushback: 0, interrupts: 0, lessons: 0, problems: 0)
    problems = (try? c.decode([String].self, forKey: .problems)) ?? []
    runs = (try? c.decode([Run].self, forKey: .runs)) ?? []
    lessons = (try? c.decode([String].self, forKey: .lessons)) ?? []
    report = (try? c.decode(String.self, forKey: .report)) ?? ""
    retro = try? c.decode(RetroReport.self, forKey: .retro)
  }
}

struct RetroReport: Decodable, Equatable {
  struct Finding: Decodable, Equatable, Identifiable {
    let id: String
    let cause: String
    let severity: String
    let title: String
    let evidence: [String]
    let file: String?
    let old: String?
    let new: String?

    enum Key: String, CodingKey { case id, cause, severity, title, evidence, file, old, new }

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: Key.self)
      id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
      cause = (try? c.decode(String.self, forKey: .cause)) ?? "Finding"
      severity = (try? c.decode(String.self, forKey: .severity)) ?? "low"
      title = (try? c.decode(String.self, forKey: .title)) ?? "Untitled finding"
      evidence = (try? c.decode([String].self, forKey: .evidence)) ?? []
      file = try? c.decode(String.self, forKey: .file)
      old = try? c.decode(String.self, forKey: .old)
      new = try? c.decode(String.self, forKey: .new)
    }
  }

  struct Applied: Decodable, Equatable {
    let at: String
    let ids: [String]
    let skipped: [String]
    let pr: String?
  }

  let at: String
  let summary: String
  let findings: [Finding]
  let applied: Applied?

  enum Key: String, CodingKey { case at, summary, findings, applied }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: Key.self)
    at = (try? c.decode(String.self, forKey: .at)) ?? ""
    summary = (try? c.decode(String.self, forKey: .summary)) ?? ""
    findings = (try? c.decode([Finding].self, forKey: .findings)) ?? []
    applied = try? c.decode(Applied.self, forKey: .applied)
  }
}

@MainActor @Observable
final class Health {
  static let shared = Health()

  private(set) var bySkill: [String: SkillHealth] = [:]
  private(set) var loadedAt: [String: Date] = [:]
  private(set) var loading: Set<String> = []
  private(set) var started: [String: Date] = [:]
  private(set) var failure: [String: String] = [:]

  func load(_ skill: String, store: Store, force: Bool = false) async {
    if !force, let at = loadedAt[skill], Date().timeIntervalSince(at) < 300 { return }
    guard !loading.contains(skill) else { return }
    guard let script = Self.script(store.paths) else {
      failure[skill] = "scripts/skill-health.sh with --json is not on this Mac yet."
      return
    }
    loading.insert(skill)
    started[skill] = Date()
    let result = await Shell.pipe(["bash", script.path, "--json", skill], in: store.paths.repo, input: Data())
    loading.remove(skill)
    loadedAt[skill] = Date()
    if result.ok, let data = result.out.data(using: .utf8), let h = try? JSONDecoder().decode(SkillHealth.self, from: data) {
      if bySkill[skill] != h { bySkill[skill] = h }
      failure[skill] = nil
    } else {
      failure[skill] = result.err.split(separator: "\n").last.map(String.init) ?? "skill-health.sh --json \(skill) failed."
    }
  }

  static func script(_ paths: Paths) -> URL? {
    let scripts = candidates(paths).map { $0.appending(path: "scripts/skill-health.sh") }.filter { (Reader.text($0) ?? "").contains("--json") }
    return scripts.first { (Reader.text($0) ?? "").contains("skill-health\"") } ?? scripts.first
  }

  static func retroHome(_ paths: Paths) -> URL {
    candidates(paths).first { (Reader.text($0.appending(path: ".claude/skills/retro/SKILL.md")) ?? "").contains("report") } ?? paths.repo
  }

  private static func candidates(_ paths: Paths) -> [URL] {
    let fm = FileManager.default
    let trees = ((try? fm.contentsOfDirectory(at: paths.repo.appending(path: ".claude/worktrees"), includingPropertiesForKeys: nil)) ?? [])
      .sorted {
        ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
          > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
      }
    return [paths.runner, paths.repo] + trees
  }
}

extension Store {
  func startReport(_ skill: String) {
    launch(
      "/retro \(skill) report", name: "Retro: \(title(skill))", loop: skill, in: Health.retroHome(paths), worktree: nil,
      key: "retro-report:\(skill)")
  }

  func startApply(_ skill: String, ids: [String]) {
    let stamp = DateFormatter()
    stamp.dateFormat = "yyyyMMdd-HHmm"
    launch(
      (["/retro", skill, "apply"] + ids).joined(separator: " "), name: "Retro fixes: \(title(skill))", loop: skill,
      in: Health.retroHome(paths), worktree: "retro-\(LoopSpec.short(skill))-\(stamp.string(from: Date()))", key: "retro-apply:\(skill)")
  }

  func reportTask(_ skill: String) -> BgTask? { task(key: "retro-report:\(skill)") }

  func applyTask(_ skill: String) -> BgTask? { task(key: "retro-apply:\(skill)") }
}

extension Health {
  nonisolated static func failing(_ problem: String) -> Bool {
    ["missing ", "frontmatter: SKILL.md", "frontmatter: name", "frontmatter: no description"].contains { problem.hasPrefix($0) }
  }
}
