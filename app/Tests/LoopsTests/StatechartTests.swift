import Foundation
import Testing

@testable import Loops

@Suite struct MermaidBlocks {
  @Test func everyMermaidBlockComesOutInOrder() {
    let body = """
      ## Summary

      ```mermaid
      stateDiagram-v2
        [*] --> Idle
      ```

      ```swift
      let x = 1
      ```

      ```Mermaid
      stateDiagram-v2
        Idle --> Done
      ```
      """
    #expect(Mermaid.blocks(body) == ["stateDiagram-v2\n  [*] --> Idle", "stateDiagram-v2\n  Idle --> Done"])
  }

  @Test func noMermaidBlockIsNothing() {
    #expect(Mermaid.blocks("Just text\n```\nmermaid\n```").isEmpty)
    #expect(Mermaid.blocks("").isEmpty)
    #expect(Mermaid.blocks("```mermaid\n\n```").isEmpty)
  }

  @Test func tildesLongerFencesAndWindowsLineEndingsWork() {
    #expect(Mermaid.blocks("~~~mermaid\r\nstateDiagram-v2\r\n  A --> B\r\n~~~\r\n") == ["stateDiagram-v2\n  A --> B"])
    #expect(Mermaid.blocks("````mermaid\nA\n```\nB\n````") == ["A\n```\nB"])
  }

  @Test func anIndentedFenceKeepsItsInnerIndent() {
    #expect(Mermaid.blocks("- item\n  ```mermaid\n  stateDiagram-v2\n    A --> B\n  ```") == ["stateDiagram-v2\n  A --> B"])
  }

  @Test func anUnclosedBlockRunsToTheEnd() {
    #expect(Mermaid.blocks("```mermaid\nstateDiagram-v2\n  A --> B\n") == ["stateDiagram-v2\n  A --> B"])
  }

  @Test func aBareSourceOrAFencedOneGivesTheSameChart() {
    #expect(Mermaid.source("  stateDiagram-v2\n  A --> B\n") == "stateDiagram-v2\n  A --> B")
    #expect(Mermaid.source("```mermaid\nstateDiagram-v2\n  A --> B\n```") == "stateDiagram-v2\n  A --> B")
  }
}

@Suite struct StatechartRendering {
  @Test func theCacheKeyFollowsSourceAndTheme() {
    let a = Statechart.key("stateDiagram-v2\n A --> B", theme: "light")
    #expect(a == Statechart.key("stateDiagram-v2\n A --> B", theme: "light"))
    #expect(a != Statechart.key("stateDiagram-v2\n A --> B", theme: "dark"))
    #expect(a != Statechart.key("stateDiagram-v2\n A --> C", theme: "light"))
    #expect(a.count == 32)
  }

  @Test func aParseErrorReadsAsOneLine() {
    let out = """
      could not render /var/folders/x/chart.mmd: Parse error on line 3:
        [*] --> {{
      ------^
      Expecting '$end', got '-->'
      """
    #expect(Statechart.problem(out, code: 2) == "Parse error on line 3")
  }

  @Test func missingNodeAndOfflineNpmSayWhy() {
    #expect(Statechart.problem("env: node: No such file or directory", code: 127) == "Node isn't installed, so the chart can't be drawn")
    let npm = "Installing pele@1.8.0 and @resvg/resvg-js@2.6.2 with npm in /x. This happens once.\ncannot install pele@1.8.0 and @resvg/resvg-js@2.6.2 with npm:\n  npm error network"
    #expect(Statechart.problem(npm, code: 2) == "Couldn't install the chart renderer with npm. Are you offline?")
    #expect(Statechart.problem("", code: 3) == "The renderer stopped with exit code 3")
  }
}

@Suite struct ProposalRounds {
  private func round(_ json: String) throws -> Round { try JSONDecoder().decode(Round.self, from: Data(json.utf8)) }

  @Test func aRoundCarriesItsChart() throws {
    let r = try round(#"{"settled":"s","questions":[],"done":false,"chart":"stateDiagram-v2\n  A --> B"}"#)
    #expect(r.chart == "stateDiagram-v2\n  A --> B")
  }

  @Test func aRoundWithoutAChartStillDecodes() throws {
    let r = try round(#"{"settled":"s","questions":[{"id":"q1","title":"T","question":"Q?","recommended":"Yes"}],"done":false}"#)
    #expect(r.chart == nil)
    #expect(r.questions.map(\.id) == ["q1"])
  }

  @Test func aSavedProposalKeepsItsChart() throws {
    var p = Proposal(idea: "x")
    p.rounds = [try round(#"{"settled":"s","questions":[],"done":true,"chart":"stateDiagram-v2"}"#)]
    let back = try JSONDecoder().decode(Proposal.self, from: JSONEncoder().encode(p))
    #expect(back.rounds.first?.chart == "stateDiagram-v2")
  }
}
