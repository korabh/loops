import Foundation
import Testing

@testable import Loops

private let start = Date(timeIntervalSince1970: 1_800_000_000)

private func pull(_ number: Int, branch: String = "loop/pr-fix/x") -> PullRequest {
  let json = """
    {"number":\(number),"title":"fix: thing \(number)","url":"https://github.com/o/r/pull/\(number)","state":"OPEN","isDraft":false,
    "mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefName":"\(branch)","headRefOid":"abc",
    "createdAt":"2027-01-15T08:00:00Z","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED","name":"check"}],"body":""}
    """
  return try! JSONDecoder().decode(PullRequest.self, from: Data(json.utf8))
}

private func folder() -> URL {
  let dir = FileManager.default.temporaryDirectory.appending(path: "loops-tests-\(UUID().uuidString)")
  try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  return dir
}

private func write(_ lines: [String], to url: URL) {
  try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try! Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
}

private func append(_ lines: [String], to url: URL) {
  let h = try! FileHandle(forWritingTo: url)
  try! h.seekToEnd()
  try! h.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
  try! h.close()
}

private func step(_ id: String, file: String, input: Int = 10, at: String = "2026-10-25T10:00:00.000Z") -> String {
  #"{"type":"assistant","timestamp":"\#(at)","message":{"model":"claude-opus-5-5","id":"\#(id)","content":[{"type":"tool_use","id":"tu-\#(id)","name":"Read","input":{"file_path":"/repo/\#(file)"}}],"usage":{"input_tokens":\#(input),"output_tokens":5}}}"#
}

@Suite struct RegexCache {
  @Test func aCachedPatternFindsTheSameGroupsEveryTime() {
    let pattern = #"/pull/(\d+)"#
    let first = Reader.groups(pattern, in: "https://github.com/o/r/pull/42")
    let again = Reader.groups(pattern, in: "https://github.com/o/r/pull/42")
    #expect(first == ["42"])
    #expect(again == first)
    #expect(Reader.groups(pattern, in: "https://github.com/o/r/pull/7") == ["7"])
    #expect(Reader.groups("(unclosed", in: "anything").isEmpty)
  }

  @Test func datesParseWithAndWithoutFractions() {
    #expect(Reader.date("2026-10-25T10:00:00.123Z") != nil)
    #expect(Reader.date("2026-10-25T10:00:00Z") != nil)
    #expect(Reader.date("yesterday") == nil)
  }
}

@MainActor
@Suite struct InboxRebuild {
  @Test func theStoredInboxMatchesTheRowsItIsBuiltFrom() {
    var waiting = BgTask(id: "w", title: "Ask: which name?", loop: "loop-tests", prompt: "p", started: start)
    waiting.state = "blocked"
    waiting.waitingFor = "input"
    let built = BgTask(id: "b", title: "Ask: build it", loop: nil, prompt: "p", started: start)
    let ready = pull(5)
    let fromTask = pull(6)
    let outcome = Outcome(
      kind: .pull, number: 5, loop: "loop-pr-fix", title: ready.tidyTitle, url: ready.url, at: start, steps: [], status: "Ready",
      done: false, stage: .ready, pr: ready, badge: "Ready", actor: "You")
    let problem = CIProblem(id: "billing", kind: .billing, title: "Billing", detail: "", at: start, action: nil)
    let input = PendingInput(title: "Which name?", detail: nil, options: [])
    let updated = start.addingTimeInterval(120)

    let rows = Store.inbox(
      tasks: [waiting, built], input: { $0.id == "w" ? input : nil }, updated: { $0.id == "w" ? updated : nil },
      pull: { $0.id == "b" ? fromTask : nil }, outcomes: [outcome], items: [], problems: [problem], state: { _ in .ready },
      loopTitle: { $0 })

    let expected = InboxRow.rows(
      answers: [
        InboxRow(id: "task:w", kind: .answer, title: "Which name?", detail: "which name?", at: updated, loop: "loop-tests", source: .task(waiting))
      ],
      items: [], waiting: [(ready, "loop-pr-fix", start), (fromTask, nil, fromTask.createdAt)],
      problems: [InboxRow(id: "ci:billing", kind: .checks, title: "Billing", detail: "", at: start, source: .problem(problem))],
      state: { _ in .ready }, loopTitle: { $0 })
    #expect(rows == expected)
    #expect(rows.map(\.id) == ["task:w", "pr-5", "pr-6", "ci:billing"])
  }
}

@MainActor
@Suite struct TaskSaves {
  @Test func aSaveWaitsAndSkipsUnchangedData() async throws {
    var writes: [Data] = []
    let saver = Saver(delay: .milliseconds(20), last: Data("a".utf8)) { writes.append($0) }
    saver.save { Data("a".utf8) }
    try await Task.sleep(for: .milliseconds(80))
    #expect(writes.isEmpty)
    saver.save { Data("b".utf8) }
    saver.save { Data("c".utf8) }
    #expect(writes.isEmpty)
    try await Task.sleep(for: .milliseconds(80))
    #expect(writes == [Data("c".utf8)])
    saver.save { Data("c".utf8) }
    saver.flush()
    #expect(writes.count == 1)
    saver.save { Data("d".utf8) }
    saver.flush()
    #expect(writes == [Data("c".utf8), Data("d".utf8)])
  }
}

@MainActor
@Suite struct SingleFlight {
  @Test func aPollJoinsTheRunInFlight() async {
    let flight = Flight()
    var runs = 0
    let work: @MainActor () async -> Void = {
      runs += 1
      try? await Task.sleep(for: .milliseconds(100))
    }
    async let a: Void = flight.run(within: 1, work)
    async let b: Void = flight.run(within: 1, work)
    _ = await (a, b)
    #expect(runs == 1)
    await flight.run(within: 60, work)
    #expect(runs == 1)
  }

  @Test func aForcedRunWhileBusyRunsOnceMore() async {
    let flight = Flight()
    var runs = 0
    let work: @MainActor () async -> Void = {
      runs += 1
      try? await Task.sleep(for: .milliseconds(100))
    }
    async let poll: Void = flight.run(within: 1, work)
    try? await Task.sleep(for: .milliseconds(30))
    #expect(flight.busy)
    async let first: Void = flight.run(work)
    async let second: Void = flight.run(work)
    _ = await (poll, first, second)
    #expect(runs == 2)
  }
}

@Suite struct Readable {
  @Test func commitsAndPathsReadAsPlainWords() {
    #expect(Briefs.readable("Checked main since 1a2b3c4d.") == "Checked main since its last run.")
    #expect(Briefs.readable("Fixed `app/Sources/Loops/Store.swift` (1712345678)") == "Fixed Store.swift")
    #expect(Briefs.readable("#12 merge after act on, 2 act on") == "#12 merge once the 2 requested fixes are in")
    #expect(Briefs.readable("Saw 1a2b3c4d..5e6f7a8b today") == "Saw the latest commits today")
  }

  @Test func aRepeatedTextGivesTheSameResult() {
    let text = "Opened https://github.com/o/r/pull/12 after 1a2b3c4d"
    #expect(Briefs.readable(text) == Briefs.readable(text))
    #expect(Briefs.attributed(text) == Briefs.attributed(text))
    #expect(String(Briefs.attributed(text).characters).contains("#12"))
  }
}

@Suite struct Reporters {
  @Test func eachFileMapsToTheSessionOrAgentThatWroteIt() {
    let root = "/c/projects/r"
    #expect(Lifecycle.reporter(of: "/elsewhere/x.json", in: [root]) == nil)
    #expect(Lifecycle.reporter(of: "\(root)/s1.jsonl", in: [root]) == "s1")
    #expect(Lifecycle.reporter(of: "\(root)/s1/subagents/agent-a7.jsonl", in: [root]) == "a7")
    #expect(Lifecycle.reporter(of: "\(root)/s1/subagents/workflows/wf_1/journal.jsonl", in: [root]) == "s1")
    #expect(Lifecycle.reporter(of: "\(root)/s1/subagents/agent-a7.meta.json", in: [root]) == "s1")
    #expect(Lifecycle.reporter(of: "\(root)/s1", in: [root]) == "")
  }
}

@Suite struct Incremental {
  @Test func spendCountsAGrowingTranscriptLikeAFreshOne() throws {
    let dir = folder()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appending(path: "a.jsonl")
    write([step("m1", file: "a.swift", input: 100), step("m2", file: "b.swift", input: 200)], to: file)
    #expect(Spend.agent(file).tokens.input == 300)
    append([step("m3", file: "c.swift", input: 400)], to: file)
    let grown = Spend.agent(file)
    let copy = dir.appending(path: "b.jsonl")
    try FileManager.default.copyItem(at: file, to: copy)
    let fresh = Spend.agent(copy)
    #expect(grown.tokens.input == 700)
    #expect(grown == fresh)
  }

  @Test func aSpendReportFindsEachKindOfRunAndRepeatsFromCache() throws {
    let config = folder()
    defer { try? FileManager.default.removeItem(at: config) }
    let runner = URL(fileURLWithPath: "/tmp/repo-spend/.claude/worktrees/loop-runner")
    let projects = config.appending(path: "projects/\(Spend.slug(runner.path))")
    let now = Date()
    let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-600))
    write(
      [
        #"{"type":"user","timestamp":"\#(stamp)","message":{"content":"<command-name>/loop-tests</command-name>"}}"#,
        step("h1", file: "a.swift", input: 50, at: stamp),
      ], to: projects.appending(path: "byhand.jsonl"))
    write([step("r1", file: "r.swift", input: 7, at: stamp)], to: projects.appending(path: "tick.jsonl"))
    let flow = projects.appending(path: "tick/subagents/workflows/wf_9")
    write(
      [
        #"{"type":"started","agentId":"m","label":"loop-docs"}"#, #"{"type":"started","agentId":"j","label":"loop-docs:judgment"}"#,
        #"{"type":"result","agentId":"m","result":{"brief":"wrote docs"}}"#, #"{"type":"result","agentId":"j","result":"fine"}"#,
      ], to: flow.appending(path: "journal.jsonl"))
    write([step("m1", file: "d.md", input: 300, at: stamp)], to: flow.appending(path: "agent-m.jsonl"))
    write([step("j1", file: "e.md", input: 20, at: stamp)], to: flow.appending(path: "agent-j.jsonl"))
    let subagents = projects.appending(path: "tick/subagents")
    write([step("s1", file: "f.swift", input: 40, at: stamp)], to: subagents.appending(path: "agent-s.jsonl"))
    try Data(#"{"description":"loop-lint"}"#.utf8).write(to: subagents.appending(path: "agent-s.meta.json"))
    write([step("k1", file: "g.swift", input: 4, at: stamp)], to: subagents.appending(path: "agent-k.jsonl"))
    try Data(#"{"parentAgentId":"s"}"#.utf8).write(to: subagents.appending(path: "agent-k.meta.json"))

    let report = Spend.report(configs: [config.path], runner: runner, tasks: [], now: now)
    let runs = Dictionary(uniqueKeysWithValues: report.runs.map { ($0.loop, $0) })
    #expect(Set(runs.keys) == ["loop-tests", "loop-docs", "loop-lint"])
    #expect(runs["loop-tests"]?.byHand == true)
    #expect(runs["loop-tests"]?.main.input == 50)
    #expect(runs["loop-docs"]?.main.input == 300)
    #expect(runs["loop-docs"]?.judgment.input == 20)
    #expect(runs["loop-docs"]?.brief == "fine")
    #expect(runs["loop-docs"]?.finished == true)
    #expect(runs["loop-lint"]?.main.input == 40)
    #expect(runs["loop-lint"]?.helpers.input == 4)
    #expect(report.runner.input == 7)
    #expect(Spend.report(configs: [config.path], runner: runner, tasks: [], now: now) == report)
  }

  @Test func liveFollowsAWorkflowAsItGrows() throws {
    let config = folder()
    defer { try? FileManager.default.removeItem(at: config) }
    let runner = URL(fileURLWithPath: "/tmp/repo/.claude/worktrees/loop-runner")
    let projects = config.appending(path: "projects/\(Spend.slug(runner.path))")
    write([#"{"type":"user","timestamp":"2026-10-25T09:59:00.000Z"}"#], to: projects.appending(path: "s1.jsonl"))
    let flow = projects.appending(path: "s1/subagents/workflows/wf_1")
    write([#"{"type":"started","agentId":"a1","label":"loop-tests"}"#], to: flow.appending(path: "journal.jsonl"))
    let agent = flow.appending(path: "agent-a1.jsonl")
    write([step("m1", file: "a.swift"), step("m2", file: "b.swift")], to: agent)

    let first = try #require(Live.read(config: config.path, runner: runner, running: [], now: Date()))
    #expect(first.id == "wf_1")
    #expect(first.agents.map(\.loop) == ["loop-tests"])
    #expect(first.agents.first?.steps == 2)
    #expect(first.agents.first?.current == "Reads b.swift")

    append([step("m3", file: "c.swift")], to: agent)
    append([#"{"type":"result","agentId":"a1","result":{"brief":"done"}}"#], to: flow.appending(path: "journal.jsonl"))
    let next = try #require(Live.read(config: config.path, runner: runner, running: [], now: Date()))
    #expect(next.agents.first?.steps == 3)
    #expect(next.agents.first?.recent.map(\.id) == [0, 1, 2])
    #expect(next.agents.first?.current == "Reads c.swift")
    #expect(next.agents.first?.finished == true)
    #expect(next.agents.first?.brief == "done")

    let later = projects.appending(path: "s1/subagents/workflows/wf_2")
    write([#"{"type":"started","agentId":"b1","label":"loop-docs"}"#], to: later.appending(path: "journal.jsonl"))
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-600)], ofItemAtPath: flow.appending(path: "journal.jsonl").path)
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: projects.appending(path: "s1/subagents/workflows").path)
    let newer = try #require(Live.read(config: config.path, runner: runner, running: [], now: Date()))
    #expect(newer.id == "wf_2")
    #expect(newer.agents.map(\.loop) == ["loop-docs"])
  }
}
