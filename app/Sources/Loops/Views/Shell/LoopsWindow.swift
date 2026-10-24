import SwiftUI

struct LoopsWindow: View {
  @Environment(Store.self) private var store
  @Environment(Workspace.self) private var workspace
  @Environment(\.openWindow) private var openWindow
  @State private var query = ""

  var body: some View {
    @Bindable var store = store
    NavigationSplitView {
      Sidebar(query: query)
        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        .searchable(text: $query, placement: .sidebar, prompt: "Search")
    } detail: {
      Detail(page: store.page ?? .home)
    }
    .toolbar { ProjectSwitcher(workspace: workspace) }
    .task { await store.refresh() }
    .onAppear { store.showWindow = { openWindow(id: "loops") } }
    .sheet(item: $store.editing) { mode in
      switch mode {
      case .add: LoopEditor(mode: mode, original: LoopDraft())
      case .edit(let l), .remove(let l): LoopEditor(mode: mode, original: store.draft(for: l))
      }
    }
    .alert(
      "Loops", isPresented: Binding(get: { store.notice != nil }, set: { if !$0 { store.notice = nil; store.retry = nil } }),
      presenting: store.notice
    ) { _ in
      if let retry = store.retry {
        Button("Do It Anyway") { store.perform("Working…", retry) }
      }
      Button("OK", role: .cancel) {}
    } message: { notice in
      Text(notice)
    }
    .background { Presenters() }
  }
}

private struct Presenters: View {
  @Environment(Store.self) private var store

  var body: some View {
    @Bindable var store = store
    ZStack {
      Color.clear
        .sheet(isPresented: $store.composing) { NewTaskSheet() }
      Color.clear
        .confirmationDialog(
          store.merges.count == 1 ? "Merge #\(store.merges[0].number) into main?" : "Merge \(store.merges.count) pull requests into main?",
          isPresented: Binding(get: { !store.merges.isEmpty }, set: { if !$0 { store.merges = [] } })
        ) {
          Button("Merge") { store.merges.forEach(store.merge) }
          Button("Cancel", role: .cancel) {}
        } message: {
          Text(store.merges.map { "#\($0.number) \($0.tidyTitle)\($0.oneWay ? " · one-way door" : "")" }.joined(separator: "\n"))
        }
      Color.clear
        .confirmationDialog(
          store.proposed.map { "Change \(store.title($0.loop)) to \($0.label)?" } ?? "",
          isPresented: Binding(get: { store.proposed != nil }, set: { if !$0 { store.proposed = nil } }),
          presenting: store.proposed
        ) { change in
          Button("Open Pull Request") { Task { await store.apply(change) } }
          Button("Cancel", role: .cancel) {}
        } message: { _ in
          Text("The change applies once its pull request merges.")
        }
    }
  }
}

private struct Detail: View {
  @Environment(Store.self) private var store
  let page: Page

  var body: some View {
    switch page {
    case .home: HomePage()
    case .inbox: InboxPage()
    case .pulls: PullsPage()
    case .tasks: TasksPage()
    case .schedule: SchedulePage()
    case .checks: ChecksPage()
    case .spend: SpendPage()
    case .plan: PlanPage()
    case .loop(let name):
      if let spec = store.specs.first(where: { $0.name == name }) {
        LoopPage(spec: spec).id(name)
      } else {
        EmptyState(title: "No Such Loop", icon: "questionmark.circle", detail: name)
      }
    case .task(let id):
      if let task = store.task(stable: id) {
        TaskPage(task: task).id(id)
      } else {
        EmptyState(title: "Task Removed", icon: "checklist")
      }
    }
  }
}

struct Sidebar: View {
  @Environment(Store.self) private var store
  let query: String
  @AppStorage("collapsedGroups") private var collapsed = ""

  private func expanded(_ group: String) -> Binding<Bool> {
    Binding(
      get: { !collapsed.split(separator: "|").contains(Substring(group)) },
      set: { open in
        var set = Set(collapsed.split(separator: "|").map(String.init))
        if open { set.remove(group) } else { set.insert(group) }
        collapsed = set.sorted().joined(separator: "|")
      })
  }

  private func matches(_ text: String) -> Bool {
    let q = query.trimmingCharacters(in: .whitespaces)
    return q.isEmpty || text.localizedCaseInsensitiveContains(q)
  }

  var body: some View {
    @Bindable var store = store
    let inbox = store.inbox.count
    List(selection: $store.page) {
      Section {
        ForEach(Page.top.filter { matches($0.title) }, id: \.self) { page in
          Label {
            HStack {
              Text(page.title)
              Spacer(minLength: 4)
              if page == .plan, store.planner.busy != nil || store.directions.busy { WorkingIcon(symbol: "asterisk", size: 12) }
            }
          } icon: {
            Image(icon: page.symbol)
          }
          .badge(page == .inbox ? inbox : 0)
          .tag(page)
        }
      }
      let tasks = store.sidebarTasks.filter { matches($0.title + " " + $0.prompt) }
      if !tasks.isEmpty {
        Section("Tasks", isExpanded: expanded("Tasks")) {
          ForEach(tasks, id: \.stable) { t in
            TaskRow(task: t).tag(Page.task(t.stable)).contextMenu { TaskMenu(task: t) }
          }
        }
      }
      ForEach(store.loopGroups) { group in
        let loops = group.loops.filter { matches($0.title + " " + $0.name + " " + (store.descriptions[$0.name] ?? "")) }
        if !loops.isEmpty {
          Section(group.name, isExpanded: expanded(group.name)) {
            ForEach(loops) { l in
              LoopRow(spec: l).tag(Page.loop(l.name)).contextMenu { LoopMenu(spec: l) }
            }
          }
        }
      }
    }
  }
}

private struct LoopRow: View {
  @Environment(Store.self) private var store
  let spec: LoopSpec

  var body: some View {
    let status = store.loopStatus(spec)
    let waiting = store.items.filter { $0.loops.contains(spec.name) }.count
    Label {
      Text(spec.title).foregroundStyle(status == .off ? .secondary : .primary)
    } icon: {
      Image(icon: Symbols.loop(spec.name))
        .foregroundStyle(status.active ? .green : status == .failed ? .red : .secondary)
        .pulsing(status.active)
    }
    .badge(waiting)
    .help("\(spec.cadence)\(spec.window.map { ", \($0)" } ?? "") · \(status.title)")
  }
}

private struct TaskRow: View {
  @Environment(Store.self) private var store
  let task: BgTask

  var body: some View {
    let phase = store.phase(task)
    Label {
      Text(Store.short(task)).lineLimit(1)
    } icon: {
      Image(icon: phase == .needsYou ? "questionmark.bubble" : Symbols.askClaude)
        .foregroundStyle(phase == .needsYou ? .orange : phase == .working ? .green : .secondary)
        .pulsing(phase == .working)
    }
    .badge(phase == .needsYou ? 1 : 0)
    .help(task.title)
  }
}
