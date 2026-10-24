import CoreServices
import SwiftUI

final class FileWatch {
  private var stream: FSEventStreamRef?
  private let handler: ([String]) -> Void
  private(set) var paths: [String] = []

  init(handler: @escaping ([String]) -> Void) { self.handler = handler }

  func start(_ wanted: [String], latency: Double) {
    let existing = wanted.filter { FileManager.default.fileExists(atPath: $0) }
    guard existing != paths || stream == nil else { return }
    stop()
    paths = existing
    guard !existing.isEmpty else { return }
    var context = FSEventStreamContext(
      version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
    let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
      guard let info else { return }
      let watch = Unmanaged<FileWatch>.fromOpaque(info).takeUnretainedValue()
      watch.handler((Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray) as? [String] ?? [])
    }
    guard
      let made = FSEventStreamCreate(
        nil, callback, &context, existing as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
        FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes))
    else { return }
    FSEventStreamSetDispatchQueue(made, .main)
    FSEventStreamStart(made)
    stream = made
  }

  func stop() {
    guard let stream else { return }
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
    self.stream = nil
    paths = []
  }
}

struct LoopSnapshot {
  var specs: [LoopSpec] = []
  var models: [String: String] = [:]
  var states: [String: LoopState] = [:]
  var briefs: [Brief] = []
  var running: [String: Date] = [:]
  var paused: Set<String> = []
  var project: ProjectConfig?
  var descriptions: [String: String] = [:]
  var lessons: [String: [String]] = [:]
  var nextTick = Date()
  var forecast: [Tick] = []
  var nextRun: [String: Date] = [:]

  static func read(paths: Paths, descriptions known: [String: String], now: Date) -> LoopSnapshot {
    var s = LoopSnapshot()
    s.project = ProjectConfig.read(paths.config) ?? ProjectConfig.read(paths.repo.appending(path: ".claude/loops.json"))
    s.specs = s.project?.specs ?? []
    s.models = Dictionary(
      uniqueKeysWithValues: s.specs.map { spec in
        let agent = Reader.text(paths.runner.appending(path: ".claude/agents/\(spec.name).md")) ?? ""
        return (spec.name, Reader.groups(#"(?m)^model:\s*(\w+)"#, in: agent).first ?? "inherit")
      })
    s.states = Reader.states(paths.loops.appending(path: "state"))
    s.briefs = Reader.briefs(paths.loops.appending(path: "log.md"))
    s.running = Reader.running(paths.locks, now: now)
    s.paused = Reader.paused(paths.paused)
    s.descriptions = known
    for spec in s.specs where s.descriptions[spec.name] == nil {
      s.descriptions[spec.name] = Reader.description(paths.skill(spec.name))
    }
    s.lessons = Dictionary(
      uniqueKeysWithValues: s.specs.map { ($0.name, Reader.tail(paths.loops.appending(path: "lessons/\($0.name).md"), 12)) })
    let last = s.states.compactMapValues(\.at)
    s.nextTick = Schedule.nextTick(after: now, recent: Array(last.values) + Array(s.running.values), in: s.project?.zone ?? .current)
    s.forecast = Schedule.forecast(s.specs.filter { !s.paused.contains($0.name) }, last: last, running: s.running, from: s.nextTick, ticks: 24 * 8)
    for t in s.forecast { for l in t.runs where s.nextRun[l.name] == nil { s.nextRun[l.name] = t.at } }
    return s
  }
}

extension Tick: Equatable {
  static func == (a: Tick, b: Tick) -> Bool { a.at == b.at && a.runs == b.runs }
}

extension LoopState: Equatable {
  static func == (a: LoopState, b: LoopState) -> Bool { a.at == b.at && a.sha == b.sha && a.json == b.json }
}

extension LiveStep: Equatable {
  static func == (a: LiveStep, b: LiveStep) -> Bool { a.id == b.id && a.at == b.at && a.text == b.text }
}

extension LiveAgent: Equatable {
  static func == (a: LiveAgent, b: LiveAgent) -> Bool {
    a.id == b.id && a.loop == b.loop && a.role == b.role && a.started == b.started && a.finished == b.finished
      && a.stalled == b.stalled && a.steps == b.steps && a.recent == b.recent && a.thought == b.thought
      && a.lastAt == b.lastAt && a.brief == b.brief && a.tokens == b.tokens
  }
}

extension LiveTick: Equatable {
  static func == (a: LiveTick, b: LiveTick) -> Bool { a.id == b.id && a.started == b.started && a.agents == b.agents }
}
