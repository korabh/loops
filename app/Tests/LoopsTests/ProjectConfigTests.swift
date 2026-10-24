import Foundation
import Testing

@testable import Loops

private func config(_ json: String) throws -> ProjectConfig {
  try JSONDecoder().decode(ProjectConfig.self, from: Data(json.utf8))
}

@Test func aLoopReadsItsCadenceHoursGroupAndTitle() throws {
  let c = try config(#"{"loops":[{"name":"loop-a","title":"Alpha","group":"Ship","every":24,"hours":[8,20],"alone":true}]}"#)
  let spec = try #require(c.specs.first)
  #expect([spec.name, spec.title, spec.group] == ["loop-a", "Alpha", "Ship"])
  #expect(spec.every == 24 && spec.from == 8 && spec.until == 20 && spec.alone)
}

@Test func aLoopWithoutATitleIsNamedAfterItself() throws {
  let spec = try #require(try config(#"{"loops":[{"name":"loop-dep-drift","every":168}]}"#).specs.first)
  #expect(spec.title == "dep-drift")
  #expect(spec.group == nil && spec.from == nil && !spec.alone)
}

@Test func aConfigWithoutLoopsHasNone() throws {
  #expect(try config(#"{"name":"Empty"}"#).specs.isEmpty)
}

@Test func loopHoursAreReadInTheProjectsTimeZone() throws {
  let c = try config(#"{"timezone":"Asia/Tokyo","loops":[{"name":"loop-a","every":1,"hours":[8,20]}]}"#)
  let spec = try #require(c.specs.first)
  let nineInTokyo = try #require(ISO8601DateFormatter().date(from: "2026-10-24T00:00:00Z"))
  #expect(Schedule.inHours(spec, at: nineInTokyo))
  var utc = spec
  utc.zone = try #require(TimeZone(identifier: "UTC"))
  #expect(!Schedule.inHours(utc, at: nineInTokyo))
}

@Test func anUnknownTimeZoneFallsBackToTheMacs() throws {
  #expect(try config(#"{"timezone":"Nowhere/Else"}"#).zone == .current)
}

@Test func theExampleConfigReadsItsLoopsAndGate() throws {
  let url = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../examples/loops.json").standardized
  let c = try #require(ProjectConfig.read(url))
  #expect(c.specs.count == c.loops?.count)
  #expect(c.specs.contains { $0.name == "loop-issue-queue" })
  #expect(c.zone.identifier == c.timezone)
  #expect(c.gate?.map(\.name) == ["typecheck", "lint", "test:convex", "test"])
}

@Test func aLoopCarriesWhatItShipsAndItsIcon() throws {
  let c = try config(#"{"loops":[{"name":"loop-notes","every":168,"ships":"a weekly changelog PR","symbol":"doc.text"}]}"#)
  let spec = try #require(c.specs.first)
  #expect(spec.ships == "a weekly changelog PR")
  Symbols.custom = ["loop-notes": "doc.text"]
  defer { Symbols.custom = [:] }
  #expect(Symbols.loop("loop-notes") == "doc.text")
  #expect(Symbols.loop("loop-pr-review") == "eye")
}

@Test func eachGateStepIsAGoalIdea() throws {
  let c = try config(#"{"gate":[{"name":"task-gate","run":"bash scripts/gate.sh \"$BASE\""},{"name":"lint","run":"bun run lint"}]}"#)
  let ideas = GoalIdea.chores(c.gate ?? [])
  #expect(ideas.map(\.title) == ["Task-gate green", "Lint green"])
  #expect(ideas[0].done.hasPrefix("bash scripts/gate.sh origin/main exits 0"))
}

@Test func theRegistryListsSharedAndEveryProjectsOwnAccounts() throws {
  let json = #"{"shared":["/a","/b"],"projects":{"/repo1":{"own":["/c"],"useShared":true},"/repo2":{"own":[],"useShared":false}}}"#
  let r = try JSONDecoder().decode(Registry.self, from: Data(json.utf8))
  #expect(Set(r.accounts) == ["/a", "/b", "/c"])
  #expect(r.projects?["/repo2"]?.useShared == false)
}

@Test func runnerStateReadsWhetherAnAccountIsTheProjectsOwn() throws {
  let json = #"{"project":"/repo","account":"/c","accounts":[{"dir":"/c","email":"c@x","limitedAt":null,"limit":null,"own":true},{"dir":"/a","email":"a@x","limitedAt":null,"limit":null,"own":false}],"useShared":true,"session":null,"limited":false,"watching":true,"busy":[],"paused":[]}"#
  let s = try JSONDecoder().decode(RunnerState.self, from: Data(json.utf8))
  #expect(s.accounts.map(\.own) == [true, false])
  #expect(s.useShared == true)
}
