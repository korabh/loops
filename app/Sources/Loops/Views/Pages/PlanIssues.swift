import SwiftUI

struct IssueLine: Identifiable {
  let issue: Issue
  let state: Handoff
  let labels: String

  var id: Int { issue.number }
  var number: Int { issue.number }
  var title: String { issue.title }
  var opened: Date { issue.createdAt ?? .distantPast }

  var rank: Int {
    switch state {
    case .open: 0
    case .queued: 1
    case .claimed, .building: 2
    case .review: 3
    }
  }
}

struct IssuesTable: View {
  @Environment(Store.self) private var store
  @Environment(\.openURL) private var openURL
  @State private var selection = Set<Int>()
  @State private var sortOrder = [KeyPathComparator(\IssueLine.number, order: .reverse)]
  @SceneStorage("IssueLineColumns") private var columns: TableColumnCustomization<IssueLine>
  @State private var query = ""

  private var handoffs: Handoffs { store.handoffs }

  var body: some View {
    let q = query.trimmingCharacters(in: .whitespaces)
    let rows = store.handoffIssues
      .filter { q.isEmpty || "#\($0.number) \($0.title)".localizedCaseInsensitiveContains(q) }
      .map { IssueLine(issue: $0, state: store.handoff($0), labels: $0.labels.filter { $0 != "ready-for-agent" }.joined(separator: ", ")) }
      .sorted(using: sortOrder)
    let picked = rows.filter { selection.contains($0.id) }.map(\.issue.url)
    Table(of: IssueLine.self, selection: $selection, sortOrder: $sortOrder, columnCustomization: $columns) {
      TableColumn("#", value: \IssueLine.number) { r in Text(verbatim: "#\(r.number)").monospacedDigit().foregroundStyle(.secondary) }
        .width(min: 44, ideal: 56)
        .customizationID("number")
      TableColumn("Title", value: \IssueLine.title) { r in Text(r.title).help(r.title) }
        .width(min: 200, ideal: 340)
        .customizationID("title")
        .disabledCustomizationBehavior(.visibility)
      TableColumn("Labels", value: \IssueLine.labels) { r in Text(r.labels).foregroundStyle(.secondary) }
        .width(min: 60, ideal: 120)
        .customizationID("labels")
      TableColumn("State", value: \IssueLine.rank) { r in HandoffState(issue: r.issue, state: r.state).environment(store) }
        .width(min: 100, ideal: 150)
        .customizationID("state")
      TableColumn("Opened", value: \IssueLine.opened) { r in
        Text(r.issue.createdAt.map { Clock.short(store.now.timeIntervalSince($0)) } ?? "").monospacedDigit().foregroundStyle(.secondary)
      }
      .width(min: 44, ideal: 60)
      .customizationID("opened")
      TableColumn("Action") { r in HandoffAction(issue: r.issue, state: r.state).buttonStyle(.bordered).environment(store) }
        .width(min: 90, ideal: 110)
        .customizationID("action")
    } rows: {
      ForEach(rows) { r in TableRow(r).draggable(r.issue.url) }
    }
    .tableAppearance()
    .contextMenu(forSelectionType: Int.self) { ids in
      if let id = ids.first, let r = rows.first(where: { $0.id == id }) { HandoffMenu(issue: r.issue, state: r.state).environment(store) }
    } primaryAction: { ids in
      for id in ids { if let r = rows.first(where: { $0.id == id }) { openURL(r.issue.url) } }
    }
    .copyable(picked)
    .focusedSceneValue(\.selected, Selected(urls: picked))
    .overlay {
      if !store.githubLoaded {
        EmptyState(loading: "Loading issues")
      } else if rows.isEmpty {
        if q.isEmpty {
          EmptyState(title: "No Open Issues", icon: "smallcircle.circle")
        } else {
          ContentUnavailableView.search(text: q)
        }
      }
    }
    .searchable(text: $query, placement: .toolbar, prompt: "Filter")
    .alert(
      "Issue", isPresented: Binding(get: { !handoffs.failure.isEmpty }, set: { if !$0 { handoffs.failure = [:] } }),
      presenting: handoffs.failure.first
    ) { _ in
      Button("OK", role: .cancel) {}
    } message: { f in
      Text("#\(f.key): \(f.value)")
    }
  }
}

private struct HandoffState: View {
  @Environment(Store.self) private var store
  let issue: Issue
  let state: Handoff

  private var handoffs: Handoffs { store.handoffs }

  var body: some View {
    if handoffs.checking.contains(issue.number) || handoffs.queuing.contains(issue.number) {
      StatusLabel(title: handoffs.checking.contains(issue.number) ? "Checking" : "Queuing", symbol: "", spinning: true)
    } else {
      switch state {
      case .open:
        if let r = handoffs.readiness[issue.number], !r.buildable {
          StatusLabel(title: "Not buildable", symbol: "exclamationmark.triangle", tint: .orange)
            .help("Missing: \(joined(r.missing))")
        } else {
          Text("Not queued").foregroundStyle(.secondary)
        }
      case .queued:
        StatusLabel(
          title: store.builderBusy ? "Queued" : "Queued\(store.nextRun["loop-issue-queue"].map { " · \(Clock.time($0))" } ?? "")",
          symbol: "clock")
      case .claimed(let who):
        StatusLabel(title: "Claimed · \(who)", symbol: "person")
      case .building:
        StatusLabel(title: "Building", symbol: "", spinning: true)
      case .review(let pr):
        let s = store.mergeState(pr)
        StatusLabel(title: "#\(pr.number) · \(s.title)", symbol: s.stage.symbol, tint: s.stage.tint)
      }
    }
  }
}

private struct HandoffAction: View {
  @Environment(Store.self) private var store
  @Environment(\.openURL) private var openURL
  let issue: Issue
  let state: Handoff

  private var handoffs: Handoffs { store.handoffs }

  var body: some View {
    let busy = handoffs.checking.contains(issue.number) || handoffs.queuing.contains(issue.number)
    switch state {
    case .open:
      if let r = handoffs.readiness[issue.number], !r.buildable {
        Button("Sharpen") { sharpen(issue, store: store) }
          .disabled(store.planner.proposal != nil || store.planner.busy != nil)
          .help("Grill it in Propose into a spec that replaces this issue's body")
      } else {
        Button("Build") { Task { await handoffs.build(issue, store: store) } }
          .disabled(busy)
          .help("Check the acceptance criteria, then queue it for Issue builder")
      }
    case .queued:
      Button("Build Now") { store.buildNow(issue) }
        .disabled(busy || store.asking.contains("build:\(issue.number)") || store.builderBusy)
    case .claimed, .building:
      EmptyView()
    case .review(let pr):
      Button { openURL(pr.url) } label: { Text(verbatim: "#\(pr.number)") }.buttonStyle(.link)
    }
  }
}

private struct HandoffMenu: View {
  @Environment(Store.self) private var store
  @Environment(\.openURL) private var openURL
  let issue: Issue
  let state: Handoff

  private var handoffs: Handoffs { store.handoffs }

  var body: some View {
    Button("Open Issue", systemImage: "safari") { openURL(issue.url) }
    if case .review(let pr) = state {
      Button("Open PR #\(pr.number)", systemImage: "arrow.triangle.pull") { openURL(pr.url) }
    }
    if state == .open {
      Button("Queue Anyway", systemImage: "tray.and.arrow.down") { Task { await handoffs.queue(issue, store: store) } }
      Button("Sharpen", systemImage: "sparkles") { sharpen(issue, store: store) }
    }
    if state == .queued {
      Button("Unqueue", systemImage: "tray.and.arrow.up") { Task { await handoffs.unqueue(issue, store: store) } }
    }
  }
}
