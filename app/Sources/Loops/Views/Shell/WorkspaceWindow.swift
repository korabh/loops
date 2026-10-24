import SwiftUI

struct WorkspaceWindow: View {
  @Environment(Workspace.self) private var workspace

  var body: some View {
    if workspace.projects.isEmpty {
      NoProjects()
    } else if workspace.all {
      AllProjectsWindow()
    } else if let store = workspace.focus {
      LoopsWindow().environment(store).id(store.id)
    }
  }
}

struct ProjectPicker: View {
  @Environment(Workspace.self) private var workspace

  var body: some View {
    @Bindable var workspace = workspace
    if workspace.projects.count > 1 {
      Picker("Project", selection: $workspace.selection) {
        Label("All Projects", icon: "square.stack").tag(String?.none)
        Divider()
        ForEach(workspace.ordered, id: \.id) { s in
          Text(s.name).tag(Optional(s.id))
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
    }
  }
}

private struct NoProjects: View {
  @Environment(Workspace.self) private var workspace
  @State private var choosing = false

  var body: some View {
    ContentUnavailableView {
      Label("No Projects", icon: "folder")
    } description: {
      Text(workspace.problem ?? "Add a git repository whose loops this Mac runs.")
    } actions: {
      Button("Add Project…") { choosing = true }
        .disabled(workspace.adding)
    }
    .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
      if case .success(let url) = result { workspace.add(url) }
    }
  }
}

enum AllPage: Hashable {
  case home, inbox, tasks
  case loop(project: String, name: String)
}

private struct AllProjectsWindow: View {
  @Environment(Workspace.self) private var workspace
  @State private var page: AllPage? = .home

  var body: some View {
    NavigationSplitView {
      List(selection: $page) {
        Section {
          Label("Home", icon: Page.home.symbol).tag(AllPage.home)
          Label("Inbox", icon: Page.inbox.symbol)
            .badge(workspace.projects.map(\.inbox.count).reduce(0, +))
            .tag(AllPage.inbox)
          Label("Tasks", icon: Page.tasks.symbol).tag(AllPage.tasks)
        }
        ForEach(workspace.ordered, id: \.id) { s in
          ForEach(s.loopGroups) { group in
            Section("\(s.name) · \(group.name)") {
              ForEach(group.loops) { l in
                Label(l.title, icon: Symbols.loop(l.name))
                  .tag(AllPage.loop(project: s.id, name: l.name))
              }
            }
          }
        }
      }
      .safeAreaBar(edge: .top) { ProjectPicker() }
      .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
    } detail: {
      switch page ?? .home {
      case .home: AllHome()
      case .inbox: AllInbox()
      case .tasks: AllTasks()
      case .loop: Color.clear
      }
    }
    .onChange(of: page) { _, new in
      if case .loop(let id, let name)? = new { workspace.open(id, .loop(name)) }
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
    .navigationTitle("Home")
  }
}

private struct ProjectSummary: View {
  @Environment(Workspace.self) private var workspace
  @Environment(Store.self) private var store

  var body: some View {
    let inbox = store.inbox
    let pulls = Array(store.pulls.values)
    let shares = Attention.shares(inbox: inbox, pulls: pulls)
    let waits = store.waits(inbox)
    let loops = shares.first { $0.holder == .loops }?.count ?? 0
    let loaded = store.githubLoaded || !store.pulls.isEmpty
    Section {
      NeedsYouSummary(
        waiting: inbox.count, merged: Attention.merged(pulls, now: store.now), shares: loaded ? shares.filter { $0.count > 0 } : [],
        sentence: Attention.sentence(counts: Attention.counts(inbox), loops: loops, oldest: waits.first.map { ($0.name, $0.seconds) }),
        open: { share in workspace.open(store.id, share.first.map { _ in .inbox } ?? .pulls, inbox: share.first) }
      )
      .redacted(reason: loaded ? [] : .placeholder)
      let running = store.running.sorted { $0.value < $1.value }
      ForEach(running, id: \.key) { name, started in
        LabeledContent {
          Text(Clock.short(store.now.timeIntervalSince(started))).monospacedDigit()
        } label: {
          Label(store.title(name), icon: Symbols.loop(name)).foregroundStyle(.green)
        }
      }
    } header: {
      HStack {
        Text(store.name)
        Spacer()
        Text(store.headline).foregroundStyle(.secondary)
      }
    } footer: {
      Button("Open \(store.name)") { workspace.open(store.id, .home) }.buttonStyle(.link)
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
                workspace.open(s.id, .inbox, inbox: row.id)
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
        ContentUnavailableView("Nothing Waiting", systemImage: "tray")
      }
    }
    .navigationTitle("Inbox")
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
              Button {
                workspace.open(s.id, .task(t.stable))
              } label: {
                LabeledContent {
                  Image(icon: s.phase(t).symbol).foregroundStyle(.secondary)
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
        ContentUnavailableView("No Tasks", systemImage: "checklist")
      }
    }
    .navigationTitle("Tasks")
  }
}
