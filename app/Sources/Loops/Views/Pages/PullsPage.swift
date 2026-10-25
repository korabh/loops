import SwiftUI

struct PullRow: Identifiable {
  let outcome: Outcome
  let loop: String
  let next: String

  var id: Int { outcome.number }
  var number: Int { outcome.number }
  var title: String { outcome.title }
  var at: Date { outcome.at }
  var stageRank: Int { outcome.done ? 9 : outcome.stage.priority }

  var stageWord: String {
    switch (outcome.stage, outcome.badge) {
    case (.fixing, "Checks"): "Failing"
    case (.building, "Checks"): "Checking"
    default: outcome.badge.isEmpty ? outcome.stage.title : outcome.badge
    }
  }
}

enum PullToken: Identifiable, Hashable {
  case stage(Stage)
  case loop(String)

  var id: String {
    switch self {
    case .stage(let s): "stage:\(s.rawValue)"
    case .loop(let l): "loop:\(l)"
    }
  }
}

struct PullsPage: View {
  enum Filter: String, CaseIterable, Identifiable {
    case you, moving, done, all

    var id: String { rawValue }

    var title: String {
      switch self {
      case .you: "Needs You"
      case .moving: "In Progress"
      case .done: "Done"
      case .all: "All"
      }
    }
  }

  @Environment(Store.self) private var store
  @Environment(\.openURL) private var openURL
  @AppStorage("pullsFilter") private var filter = Filter.moving
  @AppStorage("pullsLoop") private var loop = ""
  @State private var stage: Stage?
  @State private var selection = Set<Int>()
  @State private var sortOrder = [KeyPathComparator(\PullRow.stageRank), KeyPathComparator(\PullRow.at, order: .reverse)]
  @SceneStorage("PullRowColumns") private var columns: TableColumnCustomization<PullRow>
  @State private var query = ""

  private var tokens: Binding<[PullToken]> {
    Binding(
      get: { (loop.isEmpty ? [] : [.loop(loop)]) + (stage.map { [.stage($0)] } ?? []) },
      set: { tokens in
        loop = tokens.reversed().lazy.compactMap { if case .loop(let l) = $0 { l } else { nil } }.first ?? ""
        stage = tokens.reversed().lazy.compactMap { if case .stage(let s) = $0 { s } else { nil } }.first
      })
  }

  private var shown: Binding<Filter?> {
    Binding(get: { stage == nil ? filter : nil }, set: { if let f = $0 { filter = f; stage = nil } })
  }

  private func rows() -> [PullRow] {
    let pulls = store.outcomes.filter { $0.kind == .pull && (loop.isEmpty || $0.loop == loop) }
    let shown: [Outcome] =
      if let stage { pulls.filter { !$0.done && $0.stage == stage } } else {
        switch filter {
        case .you: pulls.filter { !$0.done && $0.needsYou }
        case .moving: pulls.filter { !$0.done && !$0.needsYou }
        case .done: Array(pulls.filter(\.done).sorted { $0.at > $1.at }.prefix(60))
        case .all: pulls.filter { !$0.done } + pulls.filter(\.done).sorted { $0.at > $1.at }.prefix(60)
        }
      }
    let q = query.trimmingCharacters(in: .whitespaces)
    return
      shown
      .filter { q.isEmpty || "#\($0.number) \($0.title) \(store.title($0.loop))".localizedCaseInsensitiveContains(q) }
      .map { PullRow(outcome: $0, loop: store.title($0.loop), next: next($0)) }
      .sorted(using: sortOrder)
  }

  private func next(_ o: Outcome) -> String {
    guard let actor = o.actor, !o.done else { return "" }
    let when = o.when.flatMap { $0 > store.now ? Clock.day($0, now: store.now) : nil }
    return when.map { "\(actor) · \($0)" } ?? actor
  }

  var body: some View {
    let rows = rows()
    let picked = rows.filter { selection.contains($0.id) }
    let q = query.trimmingCharacters(in: .whitespaces)
    Table(of: PullRow.self, selection: $selection, sortOrder: $sortOrder, columnCustomization: $columns) {
      TableColumn("#", value: \PullRow.number) { r in
        Text(verbatim: "#\(r.number)").monospacedDigit().foregroundStyle(.secondary)
      }
      .width(min: 44, ideal: 56, max: 70)
      .customizationID("number")
      TableColumn("Title", value: \PullRow.title) { r in
        HStack(spacing: 6) {
          if r.outcome.pr?.oneWay == true {
            RowIcon(symbol: "exclamationmark.octagon").foregroundStyle(.red)
              .help("One-way door: hard to undo once merged")
              .accessibilityLabel("One-way door")
          }
          Text(r.title).help(r.outcome.note.map { "\(r.title)\n\($0)" } ?? r.title)
        }
      }
      .width(min: 200, ideal: 360)
      .customizationID("title")
      .disabledCustomizationBehavior(.visibility)
      TableColumn("Loop", value: \PullRow.loop).width(min: 80, ideal: 120)
        .customizationID("loop")
      TableColumn("Stage", value: \PullRow.stageRank) { r in
        StatusLabel(title: r.stageWord, symbol: r.outcome.stage.symbol, tint: r.outcome.stage.tint).help(r.outcome.status)
      }
      .width(min: 90, ideal: 120)
      .customizationID("stage")
      TableColumn("Checks") { r in
        if let c = r.outcome.pr?.checks, c.total > 0 {
          Text(c.failed > 0 ? "\(c.failed) failing" : c.pending > 0 ? "\(c.pending) running" : "\(c.passed) pass")
            .foregroundStyle(c.failed > 0 ? .red : .secondary)
            .help(c.failing.isEmpty ? "" : "Failing: \(joined(c.failing))")
        }
      }
      .width(min: 60, ideal: 80)
      .customizationID("checks")
      TableColumn("Next", value: \PullRow.next) { r in
        Text(r.next).foregroundStyle(r.outcome.needsYou ? .primary : .secondary).help(r.outcome.status)
      }
      .width(min: 80, ideal: 160)
      .customizationID("next")
      TableColumn("Age", value: \PullRow.at) { r in
        Text(Clock.short(store.now.timeIntervalSince(r.at))).monospacedDigit().foregroundStyle(.secondary)
          .help(Clock.day(r.at, now: store.now))
      }
      .width(min: 40, ideal: 56, max: 70)
      .customizationID("age")
    } rows: {
      ForEach(rows) { r in TableRow(r).draggable(r.outcome.url) }
    }
    .tableAppearance()
    .contextMenu(forSelectionType: Int.self) { ids in
      if let id = ids.first, let r = rows.first(where: { $0.id == id }) { PullMenu(outcome: r.outcome).environment(store) }
    } primaryAction: { ids in
      for id in ids { if let r = rows.first(where: { $0.id == id }) { openURL(r.outcome.url) } }
    }
    .copyable(picked.map(\.outcome.url))
    .focusedSceneValue(\.selected, Selected(urls: picked.map(\.outcome.url), pulls: picked.compactMap(\.outcome.pr)))
    .overlay {
      if rows.isEmpty {
        if !store.githubLoaded {
          EmptyState(loading: "Loading pull requests")
        } else if !q.isEmpty {
          ContentUnavailableView.search(text: q)
        } else if stage != nil || !loop.isEmpty {
          ContentUnavailableView.search
        } else {
          EmptyState(title: "No Pull Requests", icon: "arrow.triangle.pull")
        }
      }
    }
    .bottomBar {
      PipelineBar(stage: $stage).help(stats)
    }
    .pageTitle("Pull Requests")
    .searchable(text: $query, tokens: tokens, placement: .toolbar, prompt: Text("Filter")) { token in
      switch token {
      case .stage(let s): Text(s.title)
      case .loop(let l): Text(store.title(l))
      }
    }
    .searchSuggestions {
      if loop.isEmpty {
        ForEach(store.specs.filter { q.isEmpty || $0.title.localizedCaseInsensitiveContains(q) }) { spec in
          Text(spec.title).searchCompletion(PullToken.loop(spec.name))
        }
      }
    }
    .viewTabs(shown, Filter.allCases.map(Optional.some)) { $0?.title ?? "" }
    .toolbar {
      ToolbarItem(placement: .principal) {
        Picker("Show", selection: shown) {
          ForEach(Filter.allCases) { Text($0.title).tag(Optional($0)) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
      }
      ToolbarSpacer(.fixed)
      ToolbarItem { TableViewMenu() }
    }
  }

  private var stats: String {
    let start = Calendar.current.startOfDay(for: store.now.addingTimeInterval(-13 * 86400))
    let all = store.pulls.values.filter { $0.loop != nil && (loop.isEmpty || $0.loop == loop) }
    let recent = all.filter { ($0.createdAt ?? .distantPast) >= start }
    let merged = recent.filter(\.merged)
    let hours = merged.compactMap { pr in pr.createdAt.flatMap { c in pr.mergedAt.map { $0.timeIntervalSince(c) } } }
    guard store.githubLoaded else { return "" }
    return
      "14 days: \(recent.count) opened · \(merged.count) merged · \(all.filter(\.open).count) open · \(hours.isEmpty ? "–" : Clock.span(LoopPerf.median(hours))) to merge"
  }
}

private struct PipelineBar: View {
  @Environment(Store.self) private var store
  @Binding var stage: Stage?

  private static let stages: [(Stage, String, String)] = [
    (.queued, "Queued", ""), (.building, "Building", "loop-issue-queue"), (.review, "In Review", "loop-pr-review"),
    (.fixing, "Needs Fixes", "loop-pr-fix"), (.ready, "Ready", ""),
  ]

  var body: some View {
    HStack(spacing: 0) {
      ForEach(Array(Self.stages.enumerated()), id: \.offset) { _, s in
        let count = store.outcomes.filter { !$0.done && $0.stage == s.0 }.count
        if s.0 == .queued {
          StageCount(count: count, title: s.1, loop: s.2, picked: false)
            .help(s.0.hint)
        } else {
          Button {
            stage = stage == s.0 ? nil : s.0
          } label: {
            StageCount(count: count, title: s.1, loop: s.2, picked: stage == s.0)
          }
          .buttonStyle(.plain)
          .help(s.0.hint)
          .accessibilityAddTraits(stage == s.0 ? .isSelected : [])
        }
      }
    }
  }
}

private struct StageCount: View {
  @Environment(Store.self) private var store
  let count: Int
  let title: String
  let loop: String
  let picked: Bool

  var body: some View {
    VStack(spacing: 2) {
      HStack(spacing: 4) {
        Text("\(count)").font(.title3.monospacedDigit().weight(.semibold))
        if store.running[loop] != nil { WorkingIcon(symbol: Symbols.loop(loop), size: 12).accessibilityLabel("Running") }
      }
      Text(title).font(.caption).foregroundStyle(picked ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
    }
    .frame(maxWidth: .infinity)
    .contentShape(.rect)
    .accessibilityElement(children: .combine)
  }
}

struct PullMenu: View {
  @Environment(Store.self) private var store
  @Environment(\.openURL) private var openURL
  let outcome: Outcome

  var body: some View {
    Button("Open on GitHub", systemImage: "safari") { openURL(outcome.url) }
    if let f = outcome.fixes, let issue = store.issues[f] {
      Button("Open Issue #\(f)", systemImage: "smallcircle.circle") { openURL(issue.url) }
    }
    if let pr = outcome.pr, outcome.ready {
      Button("Merge…", systemImage: "arrow.triangle.merge") { store.merges = [pr] }
        .disabled(store.merging.contains(pr.number) || store.mergedNow.contains(pr.number))
    }
    if let pr = outcome.pr, pr.open, !outcome.ready {
      Button("Fix with Claude Code", systemImage: "wrench.adjustable") {
        store.askClaude(Item(id: "pr-\(pr.number)", kind: .review, pr: pr, asks: []), fix: true)
      }
    }
    if let loop = outcome.runner {
      Button("Run \(store.title(loop)) Now", systemImage: "play") { store.runNow(loop) }
        .disabled(store.running[loop] != nil || store.isStarting(loop))
    }
    Divider()
    Button("Show \(store.title(outcome.loop))", systemImage: "arrow.right") { store.page = .loop(outcome.loop) }
  }
}
