import SwiftUI

struct TaskLine: Identifiable {
  let task: BgTask
  let phase: TaskPhase
  let title: String
  let kind: String
  let loop: String
  let cost: Double
  let tokens: Int

  var id: String { task.stable }
  var started: Date { task.started }
  var rank: Int { phase.rank }
}

struct TasksPage: View {
  @Environment(Store.self) private var store
  @Environment(\.openURL) private var openURL
  @State private var selection = Set<String>()
  @State private var sortOrder = [KeyPathComparator(\TaskLine.rank), KeyPathComparator(\TaskLine.started, order: .reverse)]
  @SceneStorage("TaskLineColumns") private var columns: TableColumnCustomization<TaskLine>

  var body: some View {
    let rows = store.tasks.map { t in
      let spent = store.taskSpend(t)
      return TaskLine(
        task: t, phase: store.phase(t), title: store.title(of: t), kind: store.kind(of: t), loop: t.loop.map(store.title) ?? "",
        cost: spent?.cost ?? 0, tokens: spent?.total ?? 0)
    }
    .sorted(using: sortOrder)
    let open = rows.filter { $0.phase.open }.count
    let picked = rows.filter { selection.contains($0.id) }.map(\.task)
    let prs = picked.compactMap { store.pull(of: $0) }
    Table(rows, selection: $selection, sortOrder: $sortOrder, columnCustomization: $columns) {
      TableColumn("Title", value: \TaskLine.title) { r in Text(r.title).help(r.task.prompt) }
        .width(min: 200, ideal: 340)
        .customizationID("title")
      TableColumn("Kind", value: \TaskLine.kind).width(min: 40, ideal: 56)
        .customizationID("kind")
      TableColumn("Loop", value: \TaskLine.loop).width(min: 60, ideal: 110)
        .customizationID("loop")
      TableColumn("Status", value: \TaskLine.rank) { r in
        StatusLabel(title: store.status(r.task, r.phase), symbol: r.phase.symbol, tint: r.phase.tint, spinning: r.phase == .working)
          .help(r.task.limit?.text ?? r.task.label)
      }
      .width(min: 90, ideal: 120)
      .customizationID("status")
      TableColumn("Progress") { r in TaskProgress(task: r.task, phase: r.phase).environment(store) }
        .width(min: 80, ideal: 140)
        .customizationID("progress")
      TableColumn("Started", value: \TaskLine.started) { r in
        Text(Clock.short(store.now.timeIntervalSince(r.started))).monospacedDigit().foregroundStyle(.secondary)
          .help(Clock.day(r.started, now: store.now))
      }
      .width(min: 44, ideal: 60)
      .customizationID("started")
      TableColumn("Cost (est.)", value: \TaskLine.cost) { r in
        Text(r.cost > 0 ? r.cost.usd : "–").monospacedDigit()
      }
      .width(min: 60, ideal: 80)
      .customizationID("cost-est")
      TableColumn("Tokens", value: \TaskLine.tokens) { r in
        Text(r.tokens > 0 ? r.tokens.compact : "–").monospacedDigit().foregroundStyle(.secondary)
      }
      .width(min: 50, ideal: 70)
      .customizationID("tokens")
      TableColumn("PR") { r in
        if let pr = store.pull(of: r.task) {
          Button { openURL(pr.url) } label: { Text(verbatim: "#\(pr.number)") }.buttonStyle(.link)
        }
      }
      .width(min: 44, ideal: 60)
      .customizationID("pr")
    }
    .tableAppearance()
    .contextMenu(forSelectionType: String.self) { ids in
      if let id = ids.first, let t = store.task(stable: id) { TaskMenu(task: t).environment(store) }
    } primaryAction: { ids in
      if let id = ids.first { store.page = .task(id) }
    }
    .copyable(prs.map(\.url))
    .focusedSceneValue(\.selected, Selected(urls: prs.map(\.url), pulls: prs, tasks: picked))
    .overlay {
      if rows.isEmpty {
        ContentUnavailableView {
          Label { Text("No Tasks") } icon: { Image(icon: "checklist", size: 32) }
        } description: {
          Text("Tasks run Claude Code in the background, in their own worktree.")
        } actions: {
          Button("New Task…") { store.composing = true }
        }
      }
    }
    .navigationTitle("Tasks")
    .navigationSubtitle(open > 0 ? "\(open) open" : "")
    .toolbar {
      ToolbarSpacer(.flexible)
      ToolbarItem {
        Button("New Task…", icon: "plus") { store.composing = true }
      }
      ToolbarItem { TableViewMenu() }
    }
  }
}

struct TaskProgress: View {
  @Environment(Store.self) private var store
  let task: BgTask
  let phase: TaskPhase

  var body: some View {
    let job = store.jobs.jobs[task.id]
    if let job, job.tasksTotal > 0 {
      if task.active {
        Meter(done: job.tasksDone, total: job.tasksTotal).help(job.current ?? "")
      } else {
        Text("\(job.tasksDone) of \(job.tasksTotal) steps").foregroundStyle(.secondary)
      }
    } else if let goal = task.goal {
      Text(task.active ? "Turn \(min(goal.taken + 1, goal.turns)) of \(goal.turns)" : plural(goal.taken, "turn"))
        .foregroundStyle(.secondary)
    } else if phase == .working {
      Text(job?.current ?? job?.activity.last ?? task.recent.last ?? "Starting").foregroundStyle(.secondary)
    }
  }
}
