import Charts
import SwiftUI

struct LoopSpend: View {
  @Environment(Store.self) private var store
  let spec: LoopSpec

  var body: some View {
    let perf = store.perf(spec.name)
    let all = store.spend.week.cost
    let advice = perf.advice(model: store.models[spec.name] ?? "inherit")
    Form {
      Section("Last 7 Days") {
        LabeledContent("Spent (est.)", value: perf.tokens.spent)
        if all > 0 { LabeledContent("Share of all loops", value: (perf.cost / all).formatted(.percent.precision(.fractionLength(0)))) }
        LabeledContent(
          "Runs",
          value: "\(perf.runs.count) · \(perf.acted.count) did work · \(perf.quiet.count) idle · \(perf.failed.count) failed")
        LabeledContent("A run", value: "\(perf.perRun.usd) · \(perf.runTokens.compact) tokens · \(Clock.span(perf.minutes * 60)) median")
      }
      .redacted(reason: store.spend.loaded ? [] : .placeholder)
      if !perf.runs.isEmpty { LoopRunsSection(runs: perf.runs) }
      Section("Ways to Save") {
        if advice.isEmpty { Text("Nothing to cut this week").foregroundStyle(.secondary) }
        ForEach(advice) { a in
          LabeledContent {
            HStack {
              AdviceStatus(advice: a)
              AdviceButton(advice: a)
            }
          } label: {
            Text(a.title)
            Text(Briefs.attributed(a.detail))
          }
        }
      }
    }
    .formStyle(.grouped)
  }
}

private struct LoopRunsSection: View {
  @Environment(Store.self) private var store
  let runs: [RunStat]
  @State private var picked: String?

  private static let parts: [(String, Color)] = [
    ("The loop", .accentColor), ("Helpers", .gray), ("Review panel", .gray.opacity(0.6)), ("Judgment", .gray.opacity(0.35)),
  ]

  var body: some View {
    Section("Runs") {
      chart
      if let run = runs.first(where: { $0.id == picked }) ?? runs.last { detail(run) }
    }
  }

  private func split(_ run: RunStat) -> [(String, Tokens)] {
    [("The loop", run.main), ("Helpers", run.helpers), ("Review panel", run.panel), ("Judgment", run.judgment)].filter { !$0.1.isEmpty }
  }

  private var chart: some View {
    let names = Dictionary(uniqueKeysWithValues: runs.map { ($0.id, Clock.day($0.at, now: store.now)) })
    return Chart {
      ForEach(runs) { run in
        ForEach(split(run), id: \.0) { part in
          BarMark(x: .value("Run", run.id), y: .value("Cost", part.1.cost))
            .foregroundStyle(by: .value("Part", part.0))
            .opacity(picked == nil || picked == run.id ? 1 : 0.5)
        }
      }
    }
    .chartForegroundStyleScale(domain: Self.parts.map(\.0), range: Self.parts.map(\.1))
    .chartLegend(position: .top, alignment: .leading)
    .chartXScale(domain: runs.map(\.id))
    .chartXAxis {
      if runs.count <= 10 {
        AxisMarks { value in
          AxisValueLabel { if let id = value.as(String.self) { Text(names[id] ?? "") } }
        }
      }
    }
    .chartYAxis {
      AxisMarks(values: .automatic(desiredCount: 3)) { value in
        AxisGridLine()
        AxisValueLabel { if let v = value.as(Double.self) { Text(v.usdShort) } }
      }
    }
    .chartXSelection(value: $picked)
    .frame(height: 150)
  }

  @ViewBuilder private func detail(_ run: RunStat) -> some View {
    LabeledContent("Run", value: Clock.day(run.at, now: store.now))
    LabeledContent("Outcome", value: capitalizedFirst(run.outcome))
    LabeledContent(
      "Took",
      value: [Clock.span(run.minutes * 60), plural(run.turns, "turn"), run.reviewers > 0 ? plural(run.reviewers, "reviewer") : nil, run.byHand ? "by you" : nil]
        .compactMap { $0 }.joined(separator: " · "))
    LabeledContent("Spent", value: run.tokens.spent).help(run.tokens.detail)
    if let brief = run.brief {
      Text(Briefs.attributed(Briefs.first(Brief(id: 0, at: run.at, loop: run.loop, text: brief)))).foregroundStyle(.secondary)
    }
  }
}
