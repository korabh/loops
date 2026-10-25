import SwiftUI

struct MenuBarMenu: View {
  @Environment(Workspace.self) private var workspace
  @Environment(\.openWindow) private var openWindow

  private func show(_ store: Store, _ page: Page?, inbox: String? = nil) {
    workspace.openWindow = openWindow
    workspace.show(store.id, page, inbox: inbox)
  }

  var body: some View {
    let stores = workspace.ordered
    if stores.isEmpty {
      Button("Add Project…") {
        openWindow(id: "project")
        NSApp.activate()
      }
    }
    ForEach(stores, id: \.id) { store in
      if stores.count > 1 {
        Section(store.name) { ProjectMenu(show: show).environment(store) }
      } else {
        ProjectMenu(show: show).environment(store)
      }
    }
    Divider()
    if let store = workspace.focus {
      Button("New Task…") {
        show(store, nil)
        store.composing = true
      }
      .keyboardShortcut("n")
      Button("Open Loops") { show(store, nil) }
        .keyboardShortcut("o")
    }
    if stores.count > 1 {
      Button("All Projects") {
        workspace.openWindow = openWindow
        workspace.showAll()
      }
      .keyboardShortcut("0")
    }
    Button("Refresh") { Task { await withTaskGroup { g in for s in stores { g.addTask { await s.refreshAll() } } } } }
      .keyboardShortcut("r")
    Divider()
    SettingsLink { Text("Settings…") }
      .keyboardShortcut(",")
    Button("Quit Loops") { NSApp.terminate(nil) }
      .keyboardShortcut("q")
  }
}

private struct ProjectMenu: View {
  @Environment(Store.self) private var store
  let show: (Store, Page, String?) -> Void

  var body: some View {
    let inbox = store.inbox
    Text(store.headline)
    Text("Next tick \(Clock.time(store.nextTick))")
    if !store.phase.healthy, store.phase != .unknown {
      Text(store.sentence)
    }
    if !inbox.isEmpty {
      Menu("Needs You (\(inbox.count))") {
        ForEach(inbox.prefix(8)) { row in
          Button(row.title, systemImage: row.kind.symbol) { show(store, .inbox, row.id) }
        }
        if inbox.count > 8 {
          Button("Show All \(inbox.count)") { show(store, .inbox, nil) }
        }
      }
    }
    let running = store.running.sorted { $0.value < $1.value }
    ForEach(running, id: \.key) { name, started in
      Button("\(store.title(name)) · \(Clock.short(store.now.timeIntervalSince(started)))") { show(store, .loop(name), nil) }
    }
    Menu("Run Now") {
      ForEach(store.loopGroups) { group in
        Section(group.name) {
          ForEach(group.loops) { l in
            Button(l.title) { store.runNow(l.name) }
              .disabled(store.running[l.name] != nil || store.isStarting(l.name))
          }
        }
      }
    }
    switch store.phase {
    case .stopped:
      Button("Start Runner") { store.perform("Starting…", ["start"]) }
    case .unknown:
      EmptyView()
    default:
      Button("Stop Runner") { store.perform("Stopping…", ["stop"]) }
    }
    Button("Open Runner in Terminal") { store.attach() }
  }
}

struct LoopsCommands: Commands {
  let workspace: Workspace
  @FocusedValue(\.project) private var focused
  @Environment(\.openWindow) private var openWindow

  private func reveal(_ store: Store, _ page: Page? = nil) {
    if focused?.id == store.id {
      if let page { store.page = page }
      return
    }
    workspace.openWindow = openWindow
    workspace.show(store.id, page)
  }

  var body: some Commands {
    let store = focused ?? workspace.focus
    let projects = workspace.ordered
    SidebarCommands()
    InspectorCommands()
    CommandGroup(replacing: .newItem) {
      Button("New Task…") {
        guard let store else { return }
        reveal(store)
        store.composing = true
      }
      .keyboardShortcut("n")
      .disabled(store == nil)
      Button("New Loop…") {
        guard let store else { return }
        reveal(store)
        store.editing = .add
      }
      .keyboardShortcut("n", modifiers: [.command, .shift])
      .disabled(store == nil)
      Divider()
      Button("Add Project…") { workspace.choose() }
        .keyboardShortcut("o")
        .disabled(workspace.adding)
      Menu("Open Project") {
        ForEach(Array(projects.enumerated()), id: \.element.id) { i, s in
          Button {
            workspace.openWindow = openWindow
            workspace.show(s.id)
          } label: {
            Text(s.name)
            Text(Workspace.status([s]))
          }
          .keyboardShortcut(i < 9 ? KeyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [.command, .control]) : nil)
        }
      }
      .disabled(projects.isEmpty)
    }
    CommandMenu("Go") {
      ForEach(Array(Page.top.enumerated()), id: \.offset) { i, page in
        Button(page.title) { if let store { reveal(store, page) } }
          .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
          .disabled(store == nil)
      }
    }
    CommandGroup(before: .windowList) {
      if projects.count > 1 {
        Button("All Projects") { openWindow(id: "all") }
          .keyboardShortcut("0")
        Divider()
      }
    }
    CommandGroup(after: .toolbar) {
      Button("Refresh") {
        Task { await withTaskGroup { g in for s in workspace.projects { g.addTask { await s.refreshAll() } } } }
      }
      .keyboardShortcut("r")
    }
  }
}

struct Selected: Equatable {
  var urls: [URL] = []
  var pulls: [PullRequest] = []
  var loops: [String] = []
  var tasks: [BgTask] = []
}

extension FocusedValues {
  @Entry var selected: Selected?
  @Entry var project: Store?
}

struct ActionCommands: Commands {
  @FocusedValue(\.selected) private var selected
  @FocusedValue(\.project) private var store

  var body: some Commands {
    let s = selected ?? Selected()
    let mergeable = store.map { st in s.pulls.filter { $0.open && st.mergeState($0).mergeable } } ?? []
    CommandMenu("Actions") {
      Button("Open on GitHub") { s.urls.forEach { NSWorkspace.shared.open($0) } }
        .keyboardShortcut("o", modifiers: [.command, .shift])
        .disabled(s.urls.isEmpty)
      Button(s.urls.count > 1 ? "Copy Links" : "Copy Link") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s.urls.map(\.absoluteString).joined(separator: "\n"), forType: .string)
      }
      .keyboardShortcut("c", modifiers: [.command, .shift])
      .disabled(s.urls.isEmpty)
      Divider()
      Button(mergeable.count > 1 ? "Merge \(mergeable.count) Pull Requests…" : "Merge…") { store?.merges = mergeable }
        .keyboardShortcut("m", modifiers: [.command, .shift])
        .disabled(mergeable.isEmpty || mergeable.count != s.pulls.count)
      Button("Run Now") { s.loops.forEach { store?.runNow($0) } }
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .disabled(s.loops.isEmpty || (store.map { st in s.loops.contains { st.running[$0] != nil || st.isStarting($0) } } ?? true))
      Button("Open in Terminal") { if let t = s.tasks.first { store?.attachTask(t) } }
        .keyboardShortcut("t", modifiers: [.command, .shift])
        .disabled(s.tasks.count != 1)
    }
  }
}
