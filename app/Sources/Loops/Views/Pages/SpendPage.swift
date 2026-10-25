import SwiftUI

struct SpendLine: Identifiable {
  let perf: LoopPerf
  let today: Double
  let share: Double

  var id: String { perf.loop }
  var title: String { perf.title }
  var runs: Int { perf.runs.count }
  var didWork: Double { perf.done.isEmpty ? -1 : Double(perf.acted.count) / Double(perf.done.count) }
  var idle: Int { perf.quiet.count }
  var failed: Int { perf.failed.count }
  var perRun: Double { perf.perRun }
  var cost: Double { perf.cost }
  var tokens: Int { perf.tokens.total }
}

struct SavingLine: Identifiable {
  let advice: Advice
  let loop: String

  var id: String { advice.id }
  var title: String { advice.title }
  var saves: Double { advice.saving ?? 0 }
  var tokens: Int { advice.tokens ?? 0 }
}

struct SpendPage: View {
  enum Tab: String, CaseIterable, Identifiable {
    case loops, save

    var id: String { rawValue }
    var title: String { self == .loops ? "Loops" : "Ways to Save" }
  }

  @Environment(Store.self) private var store
  @AppStorage("spendTab") private var tab = Tab.loops
  @State private var finding: String?

  var body: some View {
    Group {
      switch tab {
      case .loops:
        SpendTable().bottomBar { SpendPanel() }
      case .save:
        let advice = (store.fixedAdvice.map { [$0] } ?? []) + store.topAdvice
        SavingsTable(advice: advice, selection: $finding).bottomBar { SavingPanel(advice: advice.first { $0.id == finding }) }
      }
    }
    .pageTitle("Spend")
    .viewTabs($tab, Tab.allCases) { $0.title }
    .toolbar {
      ToolbarItem(placement: .principal) {
        Picker("Show", selection: $tab) {
          ForEach(Tab.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
      }
      ToolbarSpacer(.fixed)
      ToolbarItem { TableViewMenu() }
    }
  }

  static func method(_ s: SpendReport) -> String {
    let base =
      "Costs price each token at Anthropic's API rates for its model, from the loops' transcripts. The transcripts are exact for input and cache tokens, but helper agents record only part of their output, and Claude Code's own side calls never reach them."
    guard s.samples > 0 else { return base + " No finished runner session has Claude Code's own total yet, so these are lower bounds." }
    return base
      + " In \(plural(s.samples, "finished runner session")), Claude Code's own total was \(String(format: "%.2f", s.factor))× the transcript sum, so every loop cost here is scaled by that average."
  }
}

private struct SpendTable: View {
  @Environment(Store.self) private var store
  @State private var selection = Set<String>()
  @State private var sortOrder = [KeyPathComparator(\SpendLine.cost, order: .reverse)]
  @SceneStorage("SpendLineColumns") private var columns: TableColumnCustomization<SpendLine>

  var body: some View {
    let perfs = store.specs.map { store.perf($0.name) }.filter { !$0.runs.isEmpty }
    let total = max(0.0001, perfs.map(\.cost).reduce(0, +))
    let rows = perfs.map { SpendLine(perf: $0, today: store.spend.todayLoops[$0.loop]?.cost ?? 0, share: $0.cost / total) }
      .sorted(using: sortOrder)
    Table(rows, selection: $selection, sortOrder: $sortOrder, columnCustomization: $columns) {
      TableColumn("Loop", value: \SpendLine.title) { r in
        Label { Text(r.title) } icon: { RowIcon(symbol: Symbols.loop(r.id)) }
      }
      .width(min: 140, ideal: 190)
      .customizationID("loop")
      .disabledCustomizationBehavior(.visibility)
      TableColumn("Runs", value: \SpendLine.runs) { r in Text("\(r.runs)").monospacedDigit() }.width(min: 36, ideal: 44)
        .customizationID("runs")
      TableColumn("Did Work", value: \SpendLine.didWork) { r in
        Text(r.didWork < 0 ? "–" : r.didWork.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()
          .help("\(r.perf.acted.count) of \(r.perf.done.count) runs did work")
      }
      .width(min: 50, ideal: 64)
      .customizationID("did-work")
      TableColumn("Idle", value: \SpendLine.idle) { r in Text("\(r.idle)").monospacedDigit().foregroundStyle(.secondary) }
        .width(min: 32, ideal: 40)
        .customizationID("idle")
      TableColumn("Failed", value: \SpendLine.failed) { r in
        Text("\(r.failed)").monospacedDigit().foregroundStyle(r.failed > 0 ? .red : .secondary)
      }
      .width(min: 36, ideal: 48)
      .customizationID("failed")
      TableColumn("Per Run", value: \SpendLine.perRun) { r in
        Text("\(r.perRun.usd) · \(r.perf.runTokens.compact) tokens").monospacedDigit().help("Mean cost and median tokens a run")
      }
      .width(min: 90, ideal: 130)
      .customizationID("per-run")
      TableColumn("Today", value: \SpendLine.today) { r in
        Text(r.today > 0 ? r.today.usd : "–").monospacedDigit().foregroundStyle(.secondary)
      }
      .width(min: 50, ideal: 64)
      .customizationID("today")
      TableColumn("7 Days", value: \SpendLine.cost) { r in Text(r.cost.usd).monospacedDigit().fontWeight(.medium) }
        .width(min: 56, ideal: 72)
        .customizationID("7-days")
      TableColumn("Tokens", value: \SpendLine.tokens) { r in
        Text(r.tokens.compact).monospacedDigit().foregroundStyle(.secondary).help(r.perf.tokens.detail)
      }
      .width(min: 50, ideal: 64)
      .customizationID("tokens")
      TableColumn("Share", value: \SpendLine.share) { r in
        Gauge(value: r.share) { EmptyView() }
          .gaugeStyle(.accessoryLinearCapacity)
          .help(r.share.formatted(.percent.precision(.fractionLength(0))))
      }
      .width(min: 60, ideal: 100)
      .customizationID("share")
    }
    .tableAppearance()
    .contextMenu(forSelectionType: String.self) { ids in
      if let id = ids.first {
        Button("Show \(store.title(id))", systemImage: "arrow.right") { store.page = .loop(id) }
      }
    } primaryAction: { ids in
      if let id = ids.first { store.page = .loop(id) }
    }
    .focusedSceneValue(\.selected, Selected(loops: Array(selection)))
    .overlay {
      if !store.spend.loaded {
        EmptyState(loading: "Reading transcripts")
      } else if rows.isEmpty {
        EmptyState(title: "No Runs in 7 Days", icon: "chart.bar")
      }
    }
  }
}

private struct SavingsTable: View {
  @Environment(Store.self) private var store
  let advice: [Advice]
  @Binding var selection: String?
  @State private var sortOrder = [KeyPathComparator(\SavingLine.saves, order: .reverse)]
  @SceneStorage("SavingLineColumns") private var columns: TableColumnCustomization<SavingLine>

  var body: some View {
    let rows = advice.map { SavingLine(advice: $0, loop: $0.loop.map(store.title) ?? "All loops") }.sorted(using: sortOrder)
    Table(rows, selection: $selection, sortOrder: $sortOrder, columnCustomization: $columns) {
      TableColumn("Finding", value: \SavingLine.title) { r in
        Text(r.title).help(Briefs.readable(r.advice.detail))
      }
      .width(min: 180, ideal: 280)
      .customizationID("finding")
      .disabledCustomizationBehavior(.visibility)
      TableColumn("Loop", value: \SavingLine.loop) { r in Text(r.loop).foregroundStyle(.secondary) }.width(min: 80, ideal: 120)
        .customizationID("loop")
      TableColumn("Saves/Week", value: \SavingLine.saves) { r in
        Text(r.advice.saving.map { "~\($0.usd)" } ?? "–").monospacedDigit()
      }
      .width(min: 64, ideal: 84)
      .customizationID("saves-week")
      TableColumn("Tokens", value: \SavingLine.tokens) { r in
        Text(r.advice.tokens.map { $0 == 0 ? "same" : $0.compact } ?? "–").monospacedDigit().foregroundStyle(.secondary)
          .help(r.advice.label)
      }
      .width(min: 50, ideal: 70)
      .customizationID("tokens")
      TableColumn("Status") { r in AdviceStatus(advice: r.advice).environment(store) }.width(min: 90, ideal: 130)
        .customizationID("status")
      TableColumn("Action") { r in AdviceButton(advice: r.advice).buttonStyle(.bordered).environment(store) }.width(min: 110, ideal: 150)
        .customizationID("action")
    }
    .tableAppearance()
    .contextMenu(forSelectionType: String.self) { ids in
      if let id = ids.first, let a = advice.first(where: { $0.id == id }) {
        Button(store.actTitle(a), systemImage: "play") { store.act(a) }
        if let loop = a.loop {
          Button("Show \(store.title(loop))", systemImage: "arrow.right") { store.page = .loop(loop) }
        }
      }
    } primaryAction: { ids in
      if let id = ids.first, let loop = advice.first(where: { $0.id == id })?.loop { store.page = .loop(loop) }
    }
    .task(id: rows.map(\.id)) {
      if selection == nil || !rows.contains(where: { $0.id == selection }) { selection = rows.first?.id }
    }
    .overlay {
      if !store.spend.loaded {
        EmptyState(loading: "Reading transcripts")
      } else if rows.isEmpty {
        EmptyState(title: "Nothing to Cut This Week", icon: "leaf")
      }
    }
  }
}

private struct SavingPanel: View {
  @Environment(Store.self) private var store
  let advice: Advice?

  var body: some View {
    Group {
      if let a = advice {
        HStack(alignment: .top, spacing: 24) {
          VStack(alignment: .leading, spacing: 4) {
            Text(a.title).font(.headline)
            Text([a.loop.map(store.title) ?? "All loops", a.label].filter { !$0.isEmpty }.joined(separator: " · "))
              .font(.subheadline)
              .foregroundStyle(.secondary)
            Text(Briefs.attributed(a.detail))
              .foregroundStyle(.secondary)
              .lineLimit(4)
              .fixedSize(horizontal: false, vertical: true)
              .padding(.top, 2)
          }
          Spacer(minLength: 16)
          VStack(alignment: .trailing, spacing: 8) {
            AdviceStatus(advice: a)
            HStack {
              if let loop = a.loop { Button("Show \(store.title(loop))") { store.page = .loop(loop) } }
              AdviceButton(advice: a).buttonStyle(.borderedProminent)
            }
          }
        }
      } else {
        Text("Select a finding to see what it changes and act on it.").foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }
}

private struct SpendPanel: View {
  @Environment(Store.self) private var store
  @State private var method = false

  var body: some View {
    let s = store.spend
    let fixed = store.fixedContext
    HStack(alignment: .top, spacing: 24) {
      DailyCostChart(days: SpendDay.days(s.runs, now: store.now), height: 110)
        .frame(maxWidth: 420)
      Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
        GridRow {
          Text("This week (est.)").foregroundStyle(.secondary)
          Text(s.week.spent).monospacedDigit().help(s.week.detail)
        }
        GridRow {
          Text("Today").foregroundStyle(.secondary)
          Text(s.today.spent).monospacedDigit().help(s.today.detail)
        }
        GridRow {
          Text("The runner itself").foregroundStyle(.secondary)
          Text(s.runner.cost > 0 ? "\(s.runner.spent) today" : "–").monospacedDigit().help(s.runner.detail)
        }
        GridRow {
          Text("Claude Code tasks").foregroundStyle(.secondary)
          Text(s.tasks.cost > 0 ? "\(s.tasks.spent) today" : "–").monospacedDigit().help(s.tasks.detail)
        }
        GridRow {
          Text("Setup share").foregroundStyle(.secondary)
          Text(s.week.cost > 0 ? (fixed.cost / s.week.cost).formatted(.percent.precision(.fractionLength(0))) : "–")
            .monospacedDigit()
            .help("Each agent starts with \(fixed.tokens.compact) tokens of prompts, tools and skills and re-reads them every turn")
        }
      }
      Spacer(minLength: 0)
      Button("How Costs Are Estimated", icon: "info.circle") { method.toggle() }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("How costs are estimated")
        .popover(isPresented: $method, arrowEdge: .top) {
          Text(SpendPage.method(s))
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 320)
            .padding()
        }
    }
    .redacted(reason: s.loaded ? [] : .placeholder)
  }
}
