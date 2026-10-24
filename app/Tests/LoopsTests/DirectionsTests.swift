import Foundation
import Testing

@testable import Loops

private func direction(_ question: String, _ evidence: [String]) -> Direction {
  Direction(question: question, evidence: evidence, gap: "gap", rung: .teach, notYet: "not yet")
}

private func dismissal(_ question: String, _ count: Int) -> Dismissal {
  Dismissal(question: question, reason: "covered elsewhere", evidenceCount: count, at: Date())
}

@Test func evidenceCountAddsTheCountEachStringStartsWith() {
  #expect(direction("Q?", ["9 notes tagged [availability] in 2 days", "3 PR-review results name it"]).evidenceCount == 12)
}

@Test func evidenceThatDoesNotStartWithACountCountsOnce() {
  let d = direction("Q?", ["#56 reverted the midnight split twice", "2026-10-10: 3 CI notes", "Nine notes in two days"])
  #expect(d.evidenceCount == 3)
}

@Test func aDismissedDirectionStaysHiddenUntilItsEvidenceGrows() {
  let same = [direction("Should the engine resolve one window?", ["9 notes"])]
  let grown = [direction("should the engine resolve one window? ", ["9 notes", "2 asks"])]
  let gone = [dismissal("Should the engine resolve one window?", 9)]
  #expect(Directions.unseen(same, dismissed: gone).isEmpty)
  #expect(Directions.unseen(grown, dismissed: gone).count == 1)
}

@Test func aDirectionNobodyDismissedIsShown() {
  let list = [direction("A?", ["2 notes"]), direction("B?", ["4 notes"])]
  #expect(Directions.unseen(list, dismissed: [dismissal("C?", 1)]).map(\.question) == ["A?", "B?"])
}
