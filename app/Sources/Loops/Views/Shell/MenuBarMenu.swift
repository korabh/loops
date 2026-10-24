import SwiftUI

struct MenuBarMenu: View {
  @Environment(Store.self) private var store
  @Environment(\.openWindow) private var openWindow

  private func show(_ page: Page, inbox: String? = nil) {
    store.page = page
    store.inboxSelection = inbox
    openWindow(id: "loops")
    NSApp.activate()
  }

  var body: some View {
    let inbox = store.inbox
    Text(store.headline)
    Text("Next tick \(Clock.time(store.nextTick))")
    if !store.phase.healthy, store.phase != .unknown {
      Text(store.sentence)
    }
    Divider()
    if !inbox.isEmpty {
      Section("Needs You") {
        ForEach(inbox.prefix(5)) { row in
          Button(row.title, systemImage: menuSymbol(row.kind)) { show(.inbox, inbox: row.id) }
        }
        if inbox.count > 5 {
          Button("Show All \(inbox.count)") { show(.inbox) }
        }
      }
    }
    let running = store.running.sorted { $0.value < $1.value }
    if !running.isEmpty {
      Section("Running") {
        ForEach(running, id: \.key) { name, started in
          Button("\(store.title(name)) · \(Clock.short(store.now.timeIntervalSince(started)))") { show(.loop(name)) }
        }
      }
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
    Divider()
    Button("New Task…") {
      show(store.page ?? .home)
      store.composing = true
    }
    .keyboardShortcut("n")
    Button("Open Loops") { show(store.page ?? .home) }
      .keyboardShortcut("o")
    Button("Refresh") { Task { await store.refresh() } }
      .keyboardShortcut("r")
    Divider()
    switch store.phase {
    case .stopped:
      Button("Start Runner") { store.perform("Starting…", ["start"]) }
    case .unknown:
      EmptyView()
    default:
      Button("Stop Runner") { store.perform("Stopping…", ["stop"]) }
    }
    Button("Open Runner in Terminal") { store.attach() }
    Divider()
    SettingsLink { Text("Settings…") }
      .keyboardShortcut(",")
    Button("Quit Loops") { NSApp.terminate(nil) }
      .keyboardShortcut("q")
  }

  private func menuSymbol(_ kind: InboxRow.Kind) -> String {
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
  let store: Store

  var body: some Commands {
    SidebarCommands()
    InspectorCommands()
    CommandGroup(replacing: .newItem) {
      Button("New Task…") { store.composing = true }
        .keyboardShortcut("n")
      Button("New Loop…") { store.editing = .add }
        .keyboardShortcut("n", modifiers: [.command, .shift])
    }
    CommandMenu("Go") {
      ForEach(Array(Page.top.enumerated()), id: \.offset) { i, page in
        Button(page.title) { store.page = page }
          .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
      }
    }
    CommandGroup(after: .toolbar) {
      Button("Refresh") {
        Task {
          await store.refresh()
          await store.refreshSpend()
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
  let store: Store
  @FocusedValue(\.selected) private var selected

  var body: some Commands {
    let s = selected ?? Selected()
    let mergeable = s.pulls.filter { $0.open && store.mergeState($0).mergeable }
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
      Button(mergeable.count > 1 ? "Merge \(mergeable.count) Pull Requests…" : "Merge…") { store.merges = mergeable }
        .keyboardShortcut("m", modifiers: [.command, .shift])
        .disabled(mergeable.isEmpty || mergeable.count != s.pulls.count)
      Button("Run Now") { s.loops.forEach(store.runNow) }
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .disabled(s.loops.isEmpty || s.loops.contains { store.running[$0] != nil || store.isStarting($0) })
      Button("Open in Terminal") { s.tasks.first.map(store.attachTask) }
        .keyboardShortcut("t", modifiers: [.command, .shift])
        .disabled(s.tasks.count != 1)
    }
  }
}
