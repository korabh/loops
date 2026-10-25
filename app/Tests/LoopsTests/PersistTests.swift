import Foundation
import Testing

@testable import Loops

private func folder() -> URL {
  let url = FileManager.default.temporaryDirectory.appending(path: "loops-persist-\(UUID().uuidString)")
  try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private func transcript(_ url: URL, inputs: [Int], age: TimeInterval = 7200) {
  let lines = inputs.enumerated().map { i, input in
    #"{"type":"assistant","timestamp":"2026-10-25T10:00:00.000Z","message":{"model":"claude-opus-5-5","id":"m\#(i)-\#(url.lastPathComponent)","content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":\#(input),"output_tokens":5}}}"#
  }
  try! Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
  try! FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
}

private func size(_ url: URL) -> Int {
  (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
}

@Suite(.serialized) struct SpendCacheOnDisk {
  @Test func aFinishedTranscriptIsSavedWithWhereReadingStopped() throws {
    let dir = folder()
    defer { try? FileManager.default.removeItem(at: dir) }
    let before = Spend.caches
    defer { Spend.caches = before }
    Spend.caches = dir.appending(path: "caches")
    let file = dir.appending(path: "done.jsonl")
    transcript(file, inputs: [100, 200])
    #expect(Spend.agent(file).tokens.input == 300)
    Spend.persist(force: true)
    let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: Spend.caches.appending(path: "spend.json"))) as? [String: Any]
    let entry = (saved?["transcripts"] as? [String: Any])?[file.path] as? [String: Any]
    #expect(entry?["offset"] as? Int == size(file))
  }

  @Test func aRestoredTranscriptIsNotReadAgainUntilItGrows() throws {
    let dir = folder()
    defer { try? FileManager.default.removeItem(at: dir) }
    let before = Spend.caches
    defer { Spend.caches = before }
    Spend.caches = dir.appending(path: "caches")
    try FileManager.default.createDirectory(at: Spend.caches, withIntermediateDirectories: true)
    let file = dir.appending(path: "restored.jsonl")
    transcript(file, inputs: [100])
    let stat = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AgentStat(tokens: Tokens(input: 999))))
    let entry: [String: Any] = [
      "offset": size(file), "headed": false, "model": "", "acted": false, "limited": false, "stat": stat,
    ]
    let saved: [String: Any] = ["version": 1, "transcripts": [file.path: entry], "samples": [String: Any]()]
    try JSONSerialization.data(withJSONObject: saved).write(to: Spend.caches.appending(path: "spend.json"))
    Spend.restore()
    #expect(Spend.agent(file).tokens.input == 999)
    let h = try FileHandle(forWritingTo: file)
    try h.seekToEnd()
    try h.write(
      contentsOf: Data(
        (#"{"type":"assistant","timestamp":"2026-10-25T11:00:00.000Z","message":{"model":"claude-opus-5-5","id":"later","content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":50,"output_tokens":5}}}"#
          + "\n").utf8))
    try h.close()
    #expect(Spend.agent(file).tokens.input == 150)
  }
}

@MainActor
@Suite struct TaskStepsAcrossLaunches {
  @Test func aTasksLastStepsComeBackAfterARestart() throws {
    let suite = "loops-steps-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let id = "task-\(UUID().uuidString)"
    let gone = "task-\(UUID().uuidString)"
    JobActivity.of(id).add(["Read Store.swift", "Edit Store.swift"], reset: false)
    JobActivity.of(gone).add(["Read README.md"], reset: false)
    JobActivity.save(keeping: [id], to: defaults)
    JobActivity.drop([id, gone])
    JobActivity.restore(from: defaults)
    #expect(JobActivity.of(id).list == ["Read Store.swift", "Edit Store.swift"])
    #expect(JobActivity.of(gone).list.isEmpty)
  }
}

@Suite struct SpendSnapshotEncoding {
  @Test func aReportWithANonFiniteFactorStillSaves() throws {
    var report = SpendReport(loaded: true)
    report.factor = .infinity
    report.runs = [RunStat(id: "r", loop: "loop-a", at: Date(), end: Date(), fixed: .nan)]
    let data = try Spend.encoder.encode(report)
    let back = try Spend.decoder.decode(SpendReport.self, from: data)
    #expect(back.factor == .infinity)
    #expect(back.runs.first?.fixed.isNaN == true)
  }
}
