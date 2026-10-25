import SwiftUI

struct ProjectWindow: View {
  @Environment(Workspace.self) private var workspace
  @Environment(\.openWindow) private var openWindow
  @Binding var id: String

  var body: some View {
    Group {
      if let store = workspace.store(id) {
        LoopsWindow().environment(store).id(store.id)
          .onAppear { workspace.appeared(store.id) }
          .onDisappear { workspace.disappeared(store.id) }
      } else {
        ProjectChooser { id = $0 }
      }
    }
    .background(ProjectTabbing { if workspace.store(id) != nil { workspace.selection = id } })
    .onAppear { workspace.openWindow = openWindow }
  }
}

private struct ProjectChooser: View {
  @Environment(Workspace.self) private var workspace
  @Environment(\.dismiss) private var dismiss
  let open: (String) -> Void

  var body: some View {
    if workspace.projects.isEmpty {
      EmptyState(title: "No Projects", icon: "folder", detail: workspace.problem ?? "Add a git repository whose loops this Mac runs.") {
        Button("Add Project…") { workspace.choose(then: open) }
          .disabled(workspace.adding)
      }
      .navigationTitle("Projects")
    } else {
      let closed = workspace.ordered.filter { workspace.shown[$0.id] == nil }
      let opened = workspace.ordered.filter { workspace.shown[$0.id] != nil }
      Form {
        if !closed.isEmpty {
          Section("Open a Project") {
            ForEach(closed, id: \.id) { s in ProjectRow(store: s) { open(s.id) } }
          }
        }
        if !opened.isEmpty {
          Section("Already Open") {
            ForEach(opened, id: \.id) { s in
              ProjectRow(store: s) {
                workspace.show(s.id)
                dismiss()
              }
            }
          }
        }
        Section {
          HStack {
            if let problem = workspace.problem { Text(problem).foregroundStyle(.secondary) }
            Spacer()
            Button("Add Project…") { workspace.choose(then: open) }
              .disabled(workspace.adding)
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Projects")
    }
  }
}

private struct ProjectRow: View {
  let store: Store
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      LabeledContent {
        Text(Workspace.status([store])).foregroundStyle(.secondary)
      } label: {
        Text(store.name)
        Text(store.paths.repo.path).truncationMode(.middle)
      }
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
  }
}

enum AllPage: Hashable {
  case home, inbox, tasks
  case loop(project: String, name: String)
}

struct AllProjectsWindow: View {
  @Environment(Workspace.self) private var workspace
  @Environment(\.openWindow) private var openWindow
  @Environment(\.sidebarRowSize) private var rowSize
  @State private var page: AllPage? = .home

  var body: some View {
    NavigationSplitView {
      List(selection: Binding(get: { page }, set: { if let p = $0 { page = p } })) {
        Section {
          Label("Home", icon: Page.home.symbol, size: rowSize.icon).tag(AllPage.home)
          Label("Inbox", icon: Page.inbox.symbol, size: rowSize.icon)
            .badge(workspace.projects.map(\.inbox.count).reduce(0, +))
            .tag(AllPage.inbox)
          Label("Tasks", icon: Page.tasks.symbol, size: rowSize.icon).tag(AllPage.tasks)
        }
        ForEach(workspace.ordered, id: \.id) { s in
          ForEach(s.loopGroups) { group in
            Section("\(s.name) · \(group.name)") {
              ForEach(group.loops) { l in
                Label(l.title, icon: Symbols.loop(l.name), size: rowSize.icon)
                  .tag(AllPage.loop(project: s.id, name: l.name))
              }
            }
          }
        }
      }
      .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
    } detail: {
      switch page ?? .home {
      case .home: AllHome()
      case .inbox: AllInbox()
      case .tasks: AllTasks()
      case .loop: EmptyView()
      }
    }
    .navigationTitle("All Projects")
    .onChange(of: page) { old, new in
      guard case .loop(let id, let name)? = new else { return }
      workspace.show(id, .loop(name))
      page = old
    }
    .onAppear { workspace.openWindow = openWindow }
    .background {
      ForEach(workspace.projects, id: \.id) { s in Color.clear.tracksVisibility(of: s) }
    }
    .task { for s in workspace.projects { await s.refresh() } }
  }
}

private struct AllHome: View {
  @Environment(Workspace.self) private var workspace

  var body: some View {
    Form {
      ForEach(workspace.ordered, id: \.id) { s in
        ProjectSummary().environment(s)
      }
    }
    .formStyle(.grouped)
    .navigationSubtitle("Home")
  }
}

private struct ProjectSummary: View {
  @Environment(Workspace.self) private var workspace
  @Environment(Store.self) private var store

  var body: some View {
    NeedsYouSection { share in
      workspace.show(store.id, share.first.map { _ in .inbox } ?? .pulls, inbox: share.first)
    } rows: {
      RunningLoops { workspace.show(store.id, .loop($0)) }
    } header: {
      HStack {
        Text(store.name)
        Spacer()
        Text(store.headline).foregroundStyle(.secondary)
      }
    } footer: { _ in
      Button("Open \(store.name)") { workspace.show(store.id, .home) }.buttonStyle(.link)
    }
  }
}

private struct AllInbox: View {
  @Environment(Workspace.self) private var workspace

  var body: some View {
    List {
      ForEach(workspace.ordered, id: \.id) { s in
        let rows = s.inbox
        if !rows.isEmpty {
          Section(s.name) {
            ForEach(rows) { row in
              Button {
                workspace.show(s.id, .inbox, inbox: row.id)
              } label: {
                LabeledContent {
                  Text(row.at.map { Clock.day($0, now: s.now) } ?? "").foregroundStyle(.secondary)
                } label: {
                  Text(row.title).lineLimit(1)
                  Text(row.detail).lineLimit(1)
                }
              }
              .buttonStyle(.plain)
            }
          }
        }
      }
    }
    .overlay {
      if workspace.projects.allSatisfy({ $0.inbox.isEmpty }) {
        if workspace.projects.allSatisfy(\.githubLoaded) {
          EmptyState(title: "Nothing Needs You", icon: "checkmark.circle", detail: InboxPage.emptyDetail)
        } else {
          EmptyState(loading: "Loading")
        }
      }
    }
    .navigationSubtitle("Inbox")
  }
}

private struct AllTasks: View {
  @Environment(Workspace.self) private var workspace

  var body: some View {
    List {
      ForEach(workspace.ordered, id: \.id) { s in
        let tasks = s.sidebarTasks
        if !tasks.isEmpty {
          Section(s.name) {
            ForEach(tasks, id: \.stable) { t in
              let phase = s.phase(t)
              Button {
                workspace.show(s.id, .task(t.stable))
              } label: {
                LabeledContent {
                  Image(icon: phase.symbol).foregroundStyle(phase.tint)
                    .help(s.status(t, phase))
                    .accessibilityLabel(s.status(t, phase))
                } label: {
                  Text(Store.short(t)).lineLimit(1)
                }
              }
              .buttonStyle(.plain)
            }
          }
        }
      }
    }
    .overlay {
      if workspace.projects.allSatisfy({ $0.sidebarTasks.isEmpty }) {
        EmptyState(title: "No Tasks", icon: "checklist")
      }
    }
    .navigationSubtitle("Tasks")
  }
}
