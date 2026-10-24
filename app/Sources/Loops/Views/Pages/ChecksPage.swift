import SwiftUI

struct CheckLine: Identifiable {
  let run: CIRun
  let title: String
  let runner: String
  let took: Int

  var id: Int { run.id }
  var workflow: String { run.workflow }
  var branch: String { run.branch }
  var started: Date { run.started ?? .distantPast }

  var queued: Bool { run.active && run.status != "in_progress" && !run.jobs.contains { $0.status == "in_progress" || $0.status == "completed" } }

  var rank: Int {
    if queued { return 1 }
    if run.active { return 0 }
    if run.failed { return 2 }
    return run.conclusion == "success" ? 4 : 3
  }

  var status: (title: String, symbol: String, tint: Color) {
    if queued { return ("Queued", "clock", .secondary) }
    if run.active { return ("Running", "waveform", .green) }
    if run.conclusion == "success" { return ("Passed", "checkmark.circle", .green) }
    if run.billingBlocked { return ("Billing", "creditcard", .red) }
    if run.failed && run.neverRan { return ("Not started", "slash.circle", .orange) }
    if run.failed { return ("Failed", "xmark.circle", .red) }
    return ((run.conclusion ?? run.status).capitalized, "minus.circle", .secondary)
  }
}

struct ChecksPage: View {
  enum Show: String, CaseIterable, Identifiable {
    case all, running, failed

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    func matches(_ run: CIRun) -> Bool {
      switch self {
      case .all: true
      case .running: run.active
      case .failed: run.failed
      }
    }
  }

  @Environment(Store.self) private var store
  @AppStorage("ciShow") private var show = Show.all
  @AppStorage("ciWorkflow") private var workflow = ""
  @State private var selection = Set<Int>()
  @State private var sortOrder = [KeyPathComparator(\CheckLine.started, order: .reverse)]
  @SceneStorage("CheckLineColumns") private var columns: TableColumnCustomization<CheckLine>

  private var ci: CI { store.ci }

  var body: some View {
    let all = ci.board.rows + ci.board.neverStarted + ci.board.blocked
    let workflows = Array(Set(all.map(\.workflow))).sorted()
    let picked = all.filter { selection.contains($0.id) }
    let rows = all.filter { (workflow.isEmpty || $0.workflow == workflow) && show.matches($0) }.map(line).sorted(using: sortOrder)
    Table(of: CheckLine.self, selection: $selection, sortOrder: $sortOrder, columnCustomization: $columns) {
      TableColumn("Status", value: \CheckLine.rank) { r in
        let s = r.status
        StatusLabel(title: s.title, symbol: s.symbol, tint: s.tint, spinning: r.run.active && !r.queued).help(cause(r.run))
      }
      .width(min: 80, ideal: 100)
      .customizationID("status")
      TableColumn("Title", value: \CheckLine.title) { r in Text(r.title).help(r.title) }
        .width(min: 160, ideal: 300)
        .customizationID("title")
      TableColumn("Workflow", value: \CheckLine.workflow).width(min: 70, ideal: 110)
        .customizationID("workflow")
      TableColumn("Branch", value: \CheckLine.branch) { r in Text(r.branch).truncationMode(.middle).foregroundStyle(.secondary).help(r.branch) }
        .width(min: 80, ideal: 150)
        .customizationID("branch")
      TableColumn("Jobs") { r in jobs(r.run) }.width(min: 60, ideal: 110)
        .customizationID("jobs")
      TableColumn("Runner", value: \CheckLine.runner) { r in Text(r.runner).foregroundStyle(.secondary) }.width(min: 50, ideal: 80)
        .customizationID("runner")
      TableColumn("Started", value: \CheckLine.started) { r in
        Text(r.run.started.map { "\(Clock.short(store.now.timeIntervalSince($0))) ago" } ?? "").monospacedDigit().foregroundStyle(.secondary)
      }
      .width(min: 60, ideal: 80)
      .customizationID("started")
      TableColumn("Took", value: \CheckLine.took) { r in
        Text(took(r.took)).monospacedDigit().foregroundStyle(.secondary)
      }
      .width(min: 44, ideal: 64)
      .customizationID("took")
    } rows: {
      ForEach(rows) { r in TableRow(r).draggable(r.run.url) }
    }
    .tableAppearance()
    .contextMenu(forSelectionType: Int.self) { ids in
      if let id = ids.first, let run = all.first(where: { $0.id == id }) {
        RunMenu(run: run, pr: ci.pull(for: run, store: store)).environment(store)
      }
    } primaryAction: { ids in
      for id in ids { if let run = all.first(where: { $0.id == id }) { NSWorkspace.shared.open(run.url) } }
    }
    .copyable(picked.map(\.url))
    .focusedSceneValue(\.selected, Selected(urls: picked.map(\.url)))
    .overlay {
      if !ci.loaded {
        ProgressView("Loading runners and runs")
      } else if rows.isEmpty {
        EmptyState(title: all.isEmpty ? "No Runs Yet" : "No Matching Runs", icon: "checkmark.seal")
      }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      VStack(spacing: 0) {
        Divider()
        RunnerBar()
      }
      .background(.bar)
    }
    .navigationTitle("Checks")
    .navigationSubtitle(subtitle(all))
    .toolbar {
      ToolbarItem(placement: .principal) {
        Picker("Show", selection: $show) {
          ForEach(Show.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
      }
      ToolbarItem {
        Picker("Workflow", selection: $workflow) {
          Text("All Workflows").tag("")
          Divider()
          ForEach(workflows, id: \.self) { Text($0).tag($0) }
        }
        .pickerStyle(.menu)
        .fixedSize()
      }
      ToolbarItem {
        Button("Refresh", icon: "arrow.clockwise") { Task { await ci.refresh(store: store) } }
      }
      ToolbarItem { TableViewMenu() }
    }
    .task {
      while !Task.isCancelled {
        await ci.refresh(store: store)
        try? await Task.sleep(for: .seconds(ci.runs.contains(where: \.active) ? 10 : 30))
      }
    }
    .alert(
      "Checks", isPresented: Binding(get: { ci.notice != nil }, set: { if !$0 { ci.notice = nil } }), presenting: ci.notice
    ) { _ in
      Button("OK", role: .cancel) {}
    } message: { Text($0) }
  }

  private func subtitle(_ all: [CIRun]) -> String {
    let running = all.filter(\.active).count
    let failed = all.filter(\.failed).count
    return [running > 0 ? "\(running) running" : nil, failed > 0 ? "\(failed) failed" : nil].compactMap { $0 }.joined(separator: " · ")
  }

  private func line(_ run: CIRun) -> CheckLine {
    let job =
      run.jobs.first { $0.status == "in_progress" && $0.runner != nil } ?? run.jobs.first { $0.failed && $0.runner != nil }
      ?? run.jobs.first { $0.runner != nil }
    let runner: String =
      if let name = job?.runner { ci.runners.first { $0.name == name }?.short ?? (job?.hosted == true ? "GitHub" : name) } else { "" }
    let took: Int =
      if !run.active, !run.neverRan, let s = run.started, let u = run.updated, u > s { Int(u.timeIntervalSince(s)) } else { 0 }
    return CheckLine(run: run, title: ci.pull(for: run, store: store)?.tidyTitle ?? tidy(run.title), runner: runner, took: took)
  }

  private func took(_ t: Int) -> String {
    if t == 0 { return "" }
    if t < 60 { return "\(t)s" }
    if t < 3600 { return "\(t / 60)m \(t % 60)s" }
    return "\(t / 3600)h \(t % 3600 / 60)m"
  }

  @ViewBuilder private func jobs(_ run: CIRun) -> some View {
    let failing = run.jobs.filter(\.failed).map(\.name)
    if run.active, !run.jobs.isEmpty {
      let done = run.jobs.filter { $0.status == "completed" }.count
      Meter(done: done, total: run.jobs.count)
    } else if run.failed, let first = failing.first {
      Text(failing.count > 1 ? "\(first) +\(failing.count - 1)" : first).foregroundStyle(.red).help(failing.joined(separator: ", "))
    }
  }

  private func cause(_ run: CIRun) -> String {
    if run.active && run.status != "in_progress" { return "Waiting for a runner" }
    if run.active {
      let here = run.jobs.filter { $0.status == "in_progress" }.map { j in
        j.runner.flatMap { r in ci.runners.first { $0.name == r }?.short }.map { "\(j.name) on \($0)" } ?? j.name
      }
      return here.isEmpty ? "Running" : "Running \(joined(here))"
    }
    if run.billingBlocked { return "Never started: GitHub's billing blocked it" }
    if run.stuck { return "Never started: it asked for GitHub's runners, not this Mac" }
    if run.neverRan { return "Never started" }
    return (run.conclusion ?? run.status).capitalized
  }
}

private struct RunnerBar: View {
  @Environment(Store.self) private var store

  var body: some View {
    let ci = store.ci
    HStack(spacing: 16) {
      if ci.runners.isEmpty, ci.loaded {
        Text("No self-hosted runners").foregroundStyle(.secondary)
      }
      ForEach(ci.runners) { runner in
        Menu {
          Button(runner.pid == nil ? "Start" : "Restart", systemImage: "arrow.clockwise") { ci.restart(runner, store: store) }
            .disabled(runner.service == nil)
          Button("Show Log", systemImage: "doc.text.magnifyingglass") { ci.showLog(runner) }
            .disabled(runner.service == nil)
          if let url = runner.job?.url {
            Divider()
            Button("Open Job on GitHub", systemImage: "safari") { NSWorkspace.shared.open(url) }
          }
        } label: {
          StatusLabel(
            title: "\(runner.short) · \(status(runner))", symbol: "server.rack",
            tint: runner.online ? (runner.busy ? .green : .secondary) : .red, spinning: ci.acting.contains("runner:\(runner.id)"))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(runner.name)
      }
      Spacer()
      let problems = ci.problems
      if !problems.isEmpty {
        Menu {
          ForEach(problems) { p in
            if let action = p.action {
              Button("\(p.title): \(action)") { ci.perform(p, store: store) }
                .disabled(ci.busy(p))
            } else {
              Text(p.title)
            }
          }
        } label: {
          StatusLabel(title: plural(problems.count, "problem"), symbol: "exclamationmark.triangle", tint: .orange)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
  }

  private func status(_ r: Runner) -> String {
    if !r.online { return r.pid == nil ? "stopped" : "offline" }
    guard r.busy else { return "idle" }
    return r.job.map { "busy · \($0.name)" } ?? "busy"
  }
}

private struct RunMenu: View {
  @Environment(Store.self) private var store
  let run: CIRun
  let pr: PullRequest?

  var body: some View {
    let ci = store.ci
    if run.active {
      Button("Cancel Run", systemImage: "xmark") { ci.cancel(run, store: store) }
    } else if run.failed && run.hosted && !run.billingBlocked {
      if let pr, ci.mainSelfHosted, run.branch != "main" {
        Button("Update Branch from Main", systemImage: "arrow.triangle.merge") { ci.updateBranch(pr, store: store) }
      }
    } else if run.failed {
      Button("Re-run Failed Jobs", systemImage: "arrow.clockwise") { ci.rerun(run, failed: true, store: store) }
    }
    if !run.active {
      Button("Re-run All Jobs", systemImage: "arrow.clockwise") { ci.rerun(run, failed: false, store: store) }
    }
    Divider()
    Button("Open on GitHub", systemImage: "safari") { NSWorkspace.shared.open(run.url) }
    if let pr {
      Button("Open #\(pr.number)", systemImage: "arrow.triangle.pull") { NSWorkspace.shared.open(pr.url) }
    }
  }
}
