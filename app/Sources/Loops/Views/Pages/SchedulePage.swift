import SwiftUI

struct ScheduleLine: Identifiable {
  let spec: LoopSpec
  let status: LoopStatus
  let last: Date?
  let next: Date?
  let runs: Int
  let didWork: Double
  let model: String

  var id: String { spec.name }
  var title: String { spec.title }
  var group: String { spec.group ?? "Other" }
  var rank: Int { status.rank }
  var lastSort: Date { last ?? .distantPast }
  var nextSort: Date { next ?? .distantFuture }
  var every: Int { spec.every }
}

struct SchedulePage: View {
  @Environment(Store.self) private var store
  @State private var selection = Set<String>()
  @State private var sortOrder = [KeyPathComparator(\ScheduleLine.nextSort)]
  @SceneStorage("ScheduleLineColumns") private var columns: TableColumnCustomization<ScheduleLine>

  var body: some View {
    let rows = store.specs.map { l in
      let perf = store.perf(l.name)
      return ScheduleLine(
        spec: l, status: store.loopStatus(l), last: store.states[l.name]?.at, next: store.nextRun[l.name], runs: perf.runs.count,
        didWork: perf.done.isEmpty ? -1 : Double(perf.acted.count) / Double(perf.done.count), model: store.models[l.name] ?? "inherit")
    }
    .sorted(using: sortOrder)
    Table(rows, selection: $selection, sortOrder: $sortOrder, columnCustomization: $columns) {
      TableColumn("Loop", value: \ScheduleLine.title) { r in
        Label { Text(r.title) } icon: { RowIcon(symbol: Symbols.loop(r.id)) }
          .help(store.descriptions[r.id] ?? r.title)
      }
      .width(min: 140, ideal: 200)
      .customizationID("loop")
      .disabledCustomizationBehavior(.visibility)
      TableColumn("Group", value: \ScheduleLine.group).width(min: 50, ideal: 70)
        .customizationID("group")
        .defaultVisibility(.hidden)
      TableColumn("Status", value: \ScheduleLine.rank) { r in
        StatusLabel(title: r.status.title, symbol: r.status.symbol, tint: r.status.tint, spinning: r.status.active)
      }
      .width(min: 90, ideal: 130)
      .customizationID("status")
      TableColumn("Runs", value: \ScheduleLine.every) { r in
        Text(r.spec.window.map { "\(r.spec.cadence), \($0)" } ?? r.spec.cadence).foregroundStyle(.secondary)
      }
      .width(min: 80, ideal: 150)
      .customizationID("runs")
      TableColumn("Last Run", value: \ScheduleLine.lastSort) { r in
        Text(r.last.map { Clock.day($0, now: store.now) } ?? "Never").monospacedDigit().foregroundStyle(.secondary)
      }
      .width(min: 60, ideal: 90)
      .customizationID("last-run")
      TableColumn("Next Run", value: \ScheduleLine.nextSort) { r in
        Text(r.next.map { Clock.day($0, now: store.now) } ?? "–").monospacedDigit()
          .help(r.next.map { Clock.until($0, now: store.now) } ?? "Not scheduled this week")
      }
      .width(min: 60, ideal: 90)
      .customizationID("next-run")
      TableColumn("7 Days", value: \ScheduleLine.runs) { r in
        Text(r.runs == 0 ? "–" : plural(r.runs, "run")).monospacedDigit().foregroundStyle(.secondary)
      }
      .width(min: 50, ideal: 70)
      .customizationID("7-days")
      TableColumn("Did Work", value: \ScheduleLine.didWork) { r in
        Text(r.didWork < 0 ? "–" : r.didWork.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()
      }
      .width(min: 50, ideal: 70)
      .customizationID("did-work")
      TableColumn("Model", value: \ScheduleLine.model) { r in Text(r.model.capitalized).foregroundStyle(.secondary) }
        .width(min: 50, ideal: 70)
        .customizationID("model")
        .defaultVisibility(.hidden)
    }
    .tableAppearance()
    .contextMenu(forSelectionType: String.self) { ids in
      if let id = ids.first, let spec = store.specs.first(where: { $0.name == id }) { LoopMenu(spec: spec).environment(store) }
    } primaryAction: { ids in
      if let id = ids.first { store.page = .loop(id) }
    }
    .focusedSceneValue(\.selected, Selected(loops: Array(selection)))
    .overlay {
      if rows.isEmpty {
        EmptyState(title: "No Loops", icon: "calendar") {
          Button("New Loop…") { store.editing = .add }
        }
      }
    }
    .pageTitle("Schedule")
    .toolbar {
      ToolbarItem {
        Button("Run Now", icon: "play") {
          for id in selection { store.runNow(id) }
        }
        .disabled(selection.isEmpty || selection.contains { store.running[$0] != nil || store.isStarting($0) })
        .help("Start the selected loops now instead of waiting for their next tick")
      }
      ToolbarItem {
        Button("New Loop…", icon: "plus") { store.editing = .add }
          .help("Add a loop; opens a pull request")
      }
      ToolbarSpacer(.fixed)
      ToolbarItem { TableViewMenu() }
    }
  }
}
