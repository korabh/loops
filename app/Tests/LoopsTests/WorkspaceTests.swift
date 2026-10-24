import Foundation
import Testing

@testable import Loops

@Test func aRepoOwnsEventsFromItselfAndItsWorktrees() {
  let paths = Paths(repo: URL(fileURLWithPath: "/code/shop"))
  #expect(paths.contains("/code/shop"))
  #expect(paths.contains("/code/shop/.claude/worktrees/loop-runner"))
  #expect(!paths.contains("/code/shop-landing"))
  #expect(!paths.contains("/code"))
  #expect(!paths.contains(nil))
}

@MainActor @Test func eachRepoKeepsItsDataInItsOwnSuite() {
  let a = Workspace.defaults(for: "/code/shop")
  let b = Workspace.defaults(for: "/code/blog")
  let key = "test-\(UUID().uuidString)"
  a.set("shop", forKey: key)
  defer { a.removeObject(forKey: key) }
  #expect(b.string(forKey: key) == nil)
  #expect(Workspace.defaults(for: "/code/shop").string(forKey: key) == "shop")
}

@MainActor @Test func migrationCarriesOverOnlyWhatTheProjectLacks() throws {
  let from = try #require(UserDefaults(suiteName: "loops-test-from-\(UUID().uuidString)"))
  let to = try #require(UserDefaults(suiteName: "loops-test-to-\(UUID().uuidString)"))
  from.set(["a"], forKey: "dismissed")
  from.set(Data("[1]".utf8), forKey: "tasks")
  to.set(Data("[2]".utf8), forKey: "tasks")
  Workspace.carry(["dismissed", "tasks", "proposal"], from: from, to: to)
  #expect(to.stringArray(forKey: "dismissed") == ["a"])
  #expect(to.data(forKey: "tasks") == Data("[2]".utf8))
  #expect(to.object(forKey: "proposal") == nil)
}

@MainActor @Test func everyKeyAProjectSavesIsMigrated() {
  for key in ["tasks", "dismissed", "queuedFollowUps", "modelPRs", "recall", "directions", "goalIdeas", "proposal", "featureIdeas"] {
    #expect(Workspace.projectKeys.contains(key))
  }
}
