import SwiftUI

struct InboxPage: View {
  @Environment(Store.self) private var store
  @AppStorage("inboxInspector") private var inspector = true

  var body: some View {
    @Bindable var store = store
    let rows = store.inbox
    let selected = rows.first { $0.id == store.inboxSelection }
    Group {
      if rows.isEmpty {
        ContentUnavailableView {
          Label { Text(store.githubLoaded ? "Nothing Needs You" : "Loading") } icon: { Image(icon: "checkmark.circle", size: 32) }
        } description: {
          Text("Answers, merges, fixes and decisions show up here.")
        }
      } else {
        List(selection: $store.inboxSelection) {
          ForEach(InboxRow.Kind.allCases) { kind in
            let group = rows.filter { $0.kind == kind }
            if !group.isEmpty {
              Section(kind.title) {
                ForEach(group) { row in
                  InboxLine(row: row) { open(row) }
                    .tag(row.id)
                    .contextMenu { InboxMenu(row: row) }
                }
              }
            }
          }
        }
        .listStyle(.inset)
      }
    }
    .focusedSceneValue(\.selected, selected.map(Self.selection))
    .copyable(selected.map { Self.selection($0).urls } ?? [])
    .navigationTitle("Inbox")
    .navigationSubtitle(rows.isEmpty ? "" : plural(rows.count, "item"))
    .toolbar {
      ToolbarSpacer(.flexible)
      ToolbarItem {
        Button("Details", icon: "sidebar.right") { inspector.toggle() }
          .help(inspector ? "Hide details" : "Show details")
      }
    }
    .inspector(isPresented: $inspector) {
      Group {
        if let selected {
          InboxDetail(row: selected).id(selected.id)
        } else {
          EmptyState(title: "No Selection", icon: "tray", detail: "Pick an item to answer or act on it.")
        }
      }
      .inspectorColumnWidth(min: 300, ideal: 380, max: 560)
    }
    .task(id: rows.map(\.id)) {
      if selected == nil { store.inboxSelection = rows.first?.id }
    }
  }

  static func selection(_ row: InboxRow) -> Selected {
    switch row.source {
    case .task(let t): Selected(loops: t.loop.map { [$0] } ?? [], tasks: [t])
    case .item(let item): Selected(urls: item.pr.map { [$0.url] } ?? [], pulls: item.pr.map { [$0] } ?? [], loops: item.loops)
    case .problem: Selected()
    }
  }

  private func open(_ row: InboxRow) {
    store.inboxSelection = row.id
    inspector = true
  }
}

private struct InboxMenu: View {
  @Environment(Store.self) private var store
  @Environment(\.undoManager) private var undo
  @Environment(\.openURL) private var openURL
  let row: InboxRow

  var body: some View {
    switch row.source {
    case .task(let t):
      Button("Open Task", systemImage: "arrow.right") { store.page = .task(t.stable) }
      Button("Open in Terminal", systemImage: "terminal") { store.attachTask(t) }
      Divider()
      Button("Stop", systemImage: "stop", role: .destructive) { store.stopTask(t) }
    case .item(let item):
      if let pr = item.pr {
        Button("Open #\(pr.number) on GitHub", systemImage: "safari") { openURL(pr.url) }
        if store.mergeState(pr).mergeable {
          Button("Merge", systemImage: "arrow.triangle.merge") { store.merge(pr) }
            .disabled(store.merging.contains(pr.number))
        } else {
          Button("Fix with Claude Code", systemImage: "wrench.adjustable") { store.askClaude(item, fix: true) }
            .disabled(store.asking.contains(item.id))
        }
      }
      Button("Ask Claude Code", systemImage: "sparkles") { store.askClaude(item) }
        .disabled(store.asking.contains(item.id))
      if let u = item.claude {
        Button("Open in Terminal", systemImage: "terminal") { openURL(u) }
      }
      if let loop = row.loop {
        Button("Show \(store.title(loop))", systemImage: "arrow.right") { store.page = .loop(loop) }
      }
      if !item.asks.isEmpty {
        Divider()
        Button("Hide", systemImage: "eye.slash") { store.hide(item, undo: undo) }
      }
    case .problem:
      Button("Show Checks", systemImage: "checkmark.seal") { store.page = .checks }
    }
  }
}

private struct InboxDetail: View {
  @Environment(Store.self) private var store
  @Environment(\.undoManager) private var undo
  @Environment(\.openURL) private var openURL
  let row: InboxRow

  var body: some View {
    Form {
      switch row.source {
      case .task(let t):
        Section {
          AnswerForm(task: t)
        } header: {
          Text(Store.short(t))
        }
        Section {
          LabeledContent("Started", value: Clock.day(t.started, now: store.now))
          if let loop = t.loop { LabeledContent("Loop", value: store.title(loop)) }
          HStack {
            Spacer()
            Button("Open in Terminal") { store.attachTask(t) }
            Button("Open Task") { store.page = .task(t.stable) }
          }
        }
      case .item(let item):
        itemDetail(item)
      case .problem(let p):
        Section(p.title) {
          Text(p.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          HStack {
            Spacer()
            Button("Show Checks") { store.page = .checks }
            InboxAction(row: row) {}.buttonStyle(.borderedProminent)
          }
        }
      }
    }
    .formStyle(.grouped)
    .task(id: row.pr) {
      if let n = row.pr { await Statecharts.shared.fetch(n, repo: store.paths.repo) }
    }
  }

  @ViewBuilder private func itemDetail(_ item: Item) -> some View {
    if let pr = item.pr {
      let state = store.mergeState(pr)
      Section {
        LabeledContent("Pull request") {
          Button("#\(pr.number)") { openURL(pr.url) }.buttonStyle(.link)
        }
        if let loop = row.loop { LabeledContent("Loop", value: store.title(loop)) }
        LabeledContent("State") {
          StatusLabel(title: state.title, symbol: state.stage.symbol, tint: state.stage.tint)
        }
        LabeledContent("Checks", value: checks(pr.checks))
        if let v = store.verdicts[pr.number] { LabeledContent("Review", value: capitalizedFirst(Briefs.readable(v))) }
        if pr.oneWay {
          LabeledContent("Door") {
            Text("One-way: hard to undo\(pr.blast.map { " · \($0)" } ?? "")").foregroundStyle(.red)
          }
        }
        HStack {
          Spacer()
          InboxAction(row: row) {}.buttonStyle(.borderedProminent)
        }
      } header: {
        Text(Briefs.attributed(pr.tidyTitle))
      }
      PullStatecharts(pr: pr.number)
    } else {
      Section {
        Text(Briefs.attributed(item.headline)).font(.headline).fixedSize(horizontal: false, vertical: true)
        if let loop = row.loop { LabeledContent("From", value: store.title(loop)) }
        LabeledContent("Asked", value: Clock.day(item.at, now: store.now))
      }
    }
    if !item.notes.isEmpty {
      Section("Notes") {
        ForEach(Array(item.notes.enumerated()), id: \.offset) { _, n in
          Text(Briefs.attributed(capitalizedFirst(Briefs.readable(n.text)))).fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    if !item.asks.isEmpty {
      Section("Reply") {
        ReplyForm(item: item)
      }
      Section {
        HStack {
          Button("Hide") { store.hide(item, undo: undo) }
          Spacer()
          if let u = item.claude { Button("Open in Terminal") { openURL(u) } }
          Button("Ask Claude Code") { store.askClaude(item) }
            .disabled(store.asking.contains(item.id))
        }
      }
    }
  }

  private func checks(_ c: Checks) -> String {
    if c.total == 0 { return "None" }
    if c.failed > 0 { return "\(c.failed) failing\(c.failing.isEmpty ? "" : ": \(joined(Array(c.failing.prefix(3))))")" }
    if c.pending > 0 { return "\(c.pending) running" }
    return "All \(c.passed) pass"
  }
}
