import SwiftUI

struct MenuBarMenu: View {
  @Environment(Workspace.self) private var workspace
  @Environment(\.openWindow) private var openWindow

  private func show(_ store: Store, _ page: Page, inbox: String? = nil) {
    workspace.open(store.id, page, inbox: inbox)
    openWindow(id: "loops")
    NSApp.activate()
  }

  var body: some View {
    let stores = workspace.ordered
    if stores.isEmpty {
      Button("Add Project…") {
        openWindow(id: "loops")
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
        show(store, store.page ?? .home)
        store.composing = true
      }
      .keyboardShortcut("n")
    }
    Button("Open Loops") {
      openWindow(id: "loops")
      NSApp.activate()
    }
    .keyboardShortcut("o")
    Button("Refresh") { Task { for s in stores { await s.refresh() } } }
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
          Button(row.title, systemImage: Self.symbol(row.kind)) { show(store, .inbox, row.id) }
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

  static func symbol(_ kind: InboxRow.Kind) -> String {
    switch kind {
    case .answer: "questionmark.bubble"
    case .merge: "arrow.triangle.merge"
    case .fix: "wrench.adjustable"
    case .decide: "text.bubble"
    case .checks: "exclamationmark.triangle"
    }
  }
}

struct LoopsCommands: Commands {
  let workspace: Workspace

  var body: some Commands {
    let store = workspace.focus
    SidebarCommands()
    InspectorCommands()
    CommandGroup(replacing: .newItem) {
      Button("New Task…") { store?.composing = true }
        .keyboardShortcut("n")
        .disabled(store == nil)
      Button("New Loop…") { store?.editing = .add }
        .keyboardShortcut("n", modifiers: [.command, .shift])
        .disabled(store == nil)
    }
    CommandMenu("Go") {
      ForEach(Array(Page.top.enumerated()), id: \.offset) { i, page in
        Button(page.title) { if let store { workspace.open(store.id, page) } }
          .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
          .disabled(store == nil)
      }
      if workspace.projects.count > 1 {
        Divider()
        Button("All Projects") { workspace.selection = nil }
          .keyboardShortcut("0")
        ForEach(workspace.ordered, id: \.id) { s in
          Button(s.name) { workspace.selection = s.id }
        }
      }
    }
    CommandGroup(after: .toolbar) {
      Button("Refresh") {
        Task {
          for s in workspace.projects {
            await s.refresh()
            await s.refreshSpend()
          }
        }
      }
      .keyboardShortcut("r")
    }
  }
}

struct Selected {
  var urls: [URL] = []
  var pulls: [PullRequest] = []
  var loops: [String] = []
  var tasks: [BgTask] = []
}

extension FocusedValues {
  @Entry var selected: Selected?
}

struct ActionCommands: Commands {
  let workspace: Workspace
  @FocusedValue(\.selected) private var selected

  var body: some Commands {
    let s = selected ?? Selected()
    let store = workspace.focus
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
