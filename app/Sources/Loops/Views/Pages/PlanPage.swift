import SwiftUI

struct PlanPage: View {
  enum Tab: String, CaseIterable, Identifiable {
    case propose, directions, issues

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
  }

  @AppStorage("planTab") private var tab = Tab.propose

  var body: some View {
    Group {
      switch tab {
      case .propose: ProposeForm()
      case .directions: DirectionsForm()
      case .issues: IssuesTable()
      }
    }
    .navigationTitle("Plan")
    .toolbar {
      ToolbarItem(placement: .principal) {
        Picker("Show", selection: $tab) {
          ForEach(Tab.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
      }
      if tab == .issues {
        ToolbarItem { TableViewMenu() }
      }
    }
  }
}

private struct ProposeForm: View {
  @Environment(Store.self) private var store
  @Environment(\.openURL) private var openURL
  @State private var idea = ""
  @State private var replacing: FeatureIdea?

  private var planner: Planner { store.planner }

  var body: some View {
    Form {
      if let p = planner.proposal {
        proposal(p)
      } else {
        Section {
          TextField("Feature", text: $idea, prompt: Text("Describe the feature in a sentence or two"), axis: .vertical)
            .lineLimit(2...5)
            .labelsHidden()
          HStack {
            Spacer()
            Button("Start") {
              planner.start(idea, store: store)
              idea = ""
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(idea.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
        } header: {
          Text("Propose a Feature")
        } footer: {
          Text("Claude asks a few rounds of questions, each with a suggested answer, then publishes a spec as an issue.")
        }
      }
      Section {
        if planner.suggesting {
          HStack {
            ProgressView().controlSize(.small)
            Text("Suggesting features…").foregroundStyle(.secondary)
          }
        } else if let failure = planner.ideasFailure {
          Label(failure, icon: "exclamationmark.triangle").foregroundStyle(.red)
        }
        ForEach(planner.ideas) { idea in
          LabeledContent {
            Button("Explore") {
              if planner.proposal == nil { planner.explore(idea, store: store) } else { replacing = idea }
            }
            .disabled(planner.busy != nil)
          } label: {
            Text(idea.title)
            Text(idea.pitch)
          }
          .help(idea.why)
        }
      } header: {
        HStack {
          Text("Ideas from the Repo")
          Spacer()
          Button(planner.ideas.isEmpty ? "Suggest" : "Suggest Others") { planner.suggest(store: store) }
            .controlSize(.small)
            .disabled(planner.suggesting)
            .help("Claude reads the repo and lists features worth proposing")
        }
      } footer: {
        if let at = planner.ideasAt, !planner.suggesting {
          Text("\(Clock.ago(at, now: store.now))\(planner.ideasUsage.map { " · \($0.label)" } ?? "")")
        }
      }
    }
    .formStyle(.grouped)
    .confirmationDialog(
      "Explore this idea instead?", isPresented: Binding(get: { replacing != nil }, set: { if !$0 { replacing = nil } }),
      presenting: replacing
    ) { idea in
      Button("Start Over", role: .destructive) {
        planner.reset()
        planner.explore(idea, store: store)
      }
    } message: { _ in
      Text("The proposal in progress is discarded.")
    }
  }

  @ViewBuilder private func proposal(_ p: Proposal) -> some View {
    let round = p.current
    Section {
      if let n = p.target { LabeledContent("Rewrites", value: "#\(n) when published") }
      LabeledContent("Round", value: "\(max(1, p.rounds.count)) · \(p.tokens.map { Usage(tokens: $0, cost: p.cost).label } ?? p.cost.usd)")
      if let settled = round?.settled, !settled.isEmpty {
        Text(Briefs.attributed(settled)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      if let busy = planner.busy {
        HStack {
          ProgressView().controlSize(.small)
          Text("\(busy)…")
          if let since = planner.since { Text(since, style: .timer).monospacedDigit().foregroundStyle(.tertiary) }
        }
      }
      if let w = p.waiting, planner.busy == nil {
        LabeledContent {
          HStack {
            Button("Cancel") { planner.stopWaiting() }
            Button("Send Now") { planner.sendNow(store: store) }
          }
        } label: {
          Text("Waiting for the \(UsageLimit(text: w.limit, at: nil, resets: nil).kind) to reset")
          Text("It carries on by itself at \(Clock.day(w.until, now: store.now)), with what you sent.")
        }
      }
      if let failure = planner.failure {
        LabeledContent {
          if p.rounds.isEmpty {
            Button("Try Again") {
              let idea = p.idea
              planner.reset()
              planner.start(idea, store: store)
            }
          }
        } label: {
          Label(failure, icon: "exclamationmark.triangle").foregroundStyle(.red)
        }
      }
    } header: {
      HStack {
        Text(p.idea).lineLimit(2)
        Spacer()
        Button("Start Over", role: .destructive) { planner.reset() }.controlSize(.small)
      }
    }
    if let chart = p.rounds.last(where: { !($0.chart ?? "").isEmpty })?.chart {
      Section("Statechart") {
        StatechartView(source: Mermaid.source(chart), maxHeight: 360)
      }
    }
    if planner.busy == nil {
      if let issue = p.issue {
        Section {
          LabeledContent {
            HStack {
              Button("Propose Another") { planner.reset() }
              if let url = URL(string: issue) { Button("Open Issue") { openURL(url) }.buttonStyle(.borderedProminent) }
            }
          } label: {
            Text("Published\(Briefs.numbers(issue).last.map { " as #\($0)" } ?? "")")
            Text("Issue builder takes it at \(Clock.time(store.nextTick))")
          }
        }
      } else if let round, round.done {
        Section {
          LabeledContent {
            HStack {
              Button("Ask More") { planner.more(store: store) }
              Button("Publish Spec") { planner.publish(store: store) }.buttonStyle(.borderedProminent)
            }
          } label: {
            Text("Every question is settled")
            Text("Publishing writes the spec as an issue labelled ready-for-agent")
          }
        }
      } else if let round {
        ForEach(round.questions) { QuestionSection(question: $0) }
        if p.waiting == nil {
          Section {
            HStack {
              Spacer()
              Button("Send Answers") { planner.send(store: store) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
            }
          } footer: {
            Text("Every answer starts as Claude's suggestion.")
          }
        }
      }
    }
  }
}

private struct QuestionSection: View {
  @Environment(Store.self) private var store
  let question: Round.Question

  private var planner: Planner { store.planner }

  var body: some View {
    let answer = planner.answer(question.id)
    Section {
      Text(Briefs.attributed(question.question)).fixedSize(horizontal: false, vertical: true)
      let options = question.options ?? []
      if !options.isEmpty {
        Picker("Choice", selection: Binding(get: { options.contains(answer.wrappedValue) ? answer.wrappedValue : "" }, set: { answer.wrappedValue = $0 })) {
          ForEach(options, id: \.self) { o in
            Text(o == question.recommended ? "\(o) (suggested)" : o).tag(o)
          }
          Text("Something else").tag("")
        }
        .pickerStyle(.radioGroup)
        .labelsHidden()
      }
      if options.isEmpty || !options.contains(answer.wrappedValue) {
        TextField("Answer", text: answer, prompt: Text("Your answer"), axis: .vertical)
          .lineLimit(1...5)
          .labelsHidden()
      }
    } header: {
      HStack {
        Text("\(question.id.uppercased()) · \(question.title)")
        Spacer()
        if answer.wrappedValue != question.recommended {
          Button("Use Suggestion") { answer.wrappedValue = question.recommended }.controlSize(.small)
        }
      }
    } footer: {
      if let why = question.why { Text(why) }
    }
  }
}

private struct DirectionsForm: View {
  @Environment(Store.self) private var store
  @State private var dismissing: Direction?
  @State private var reason = ""
  @State private var replacing: Direction?

  private var directions: Directions { store.directions }

  var body: some View {
    let seen = Directions.fingerprint(store.paths)
    Form {
      Section {
        TextField("Destination", text: directions.destinationBinding, prompt: Text(Directions.defaultDestination), axis: .vertical)
          .lineLimit(1...3)
          .labelsHidden()
        LabeledContent("Loops needed you") {
          if let n = directions.needed {
            Text("\(plural(n.last7, "time")) in 7 days, \(n.prior7) the week before").monospacedDigit()
          } else if let problem = directions.uncounted {
            Text("Couldn't count").foregroundStyle(.secondary).help(problem)
          } else {
            ProgressView().controlSize(.small)
          }
        }
      } header: {
        Text("Where Should the Loops Get To?")
      } footer: {
        Text("Claude works back from this destination.")
      }
      Section {
        if directions.busy {
          HStack {
            ProgressView().controlSize(.small)
            Text("Reading the loops' records…").foregroundStyle(.secondary)
            if let since = directions.since { Text(since, style: .timer).monospacedDigit().foregroundStyle(.tertiary) }
          }
        } else if let failure = directions.failure {
          Label(failure, icon: "exclamationmark.triangle").foregroundStyle(.red)
        } else if directions.stale(seen) {
          Text("New records since this run. Ask again to include them.").foregroundStyle(.secondary)
        }
        if directions.at != nil, !directions.busy, directions.visible.isEmpty {
          Text(directions.list.isEmpty ? "Nothing recurring" : "Nothing new since you dismissed the last ones").foregroundStyle(.secondary)
        }
      } header: {
        HStack {
          Text("Questions You're Not Asking")
          Spacer()
          Button(directions.at == nil ? "Ask" : "Ask Again") { directions.ask(store: store) }
            .controlSize(.small)
            .disabled(directions.busy)
            .help("Claude reads the loops' notes, lessons, briefs and your answers, checks them against the code, and returns up to three directions, for at most $\(Directions.budget). It never files anything.")
        }
      } footer: {
        if let at = directions.at, !directions.busy {
          Text("\(Clock.ago(at, now: store.now))\(directions.usage.map { " · \($0.label)" } ?? "")")
        }
      }
      if directions.at != nil, !directions.busy {
        ForEach(directions.visible) { d in
          Section {
            Text(d.question).font(.headline).fixedSize(horizontal: false, vertical: true)
            Text(d.gap).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(d.evidence, id: \.self) { e in
              let parts = Reader.groups(#"^(\d+)\s+(.+)$"#, in: e)
              LabeledContent(parts.count == 2 ? parts[1] : e, value: parts.first ?? "")
            }
            VStack(alignment: .leading, spacing: 4) {
              Text("Not yet")
              Text(d.notYet).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
              Spacer()
              Button("Dismiss…") { dismissing = d }
              Button("Explore") {
                if store.planner.proposal == nil { directions.explore(d, store: store) } else { replacing = d }
              }
              .buttonStyle(.borderedProminent)
              .disabled(store.planner.busy != nil)
            }
          } header: {
            Text("\(d.rung.title) · builds \(d.rung.builds)")
          }
        }
      }
    }
    .formStyle(.grouped)
    .task(id: seen) { await directions.count(store: store) }
    .alert(
      "Why pass on this?", isPresented: Binding(get: { dismissing != nil }, set: { if !$0 { dismissing = nil } }), presenting: dismissing
    ) { d in
      TextField("Reason", text: $reason)
      Button("Dismiss") {
        directions.dismiss(d, reason: reason)
        reason = ""
      }
      .disabled(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      Button("Cancel", role: .cancel) { reason = "" }
    } message: { _ in
      Text("The next run reads your reason, and asks this again only once its evidence grows.")
    }
    .confirmationDialog(
      "Explore this direction instead?", isPresented: Binding(get: { replacing != nil }, set: { if !$0 { replacing = nil } }),
      presenting: replacing
    ) { d in
      Button("Start Over with This Direction", role: .destructive) {
        store.planner.reset()
        directions.explore(d, store: store)
      }
    } message: { _ in
      Text("The proposal in progress and its answers are discarded.")
    }
  }
}

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

private struct IssuesTable: View {
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
        ProgressView("Loading issues")
      } else if rows.isEmpty {
        EmptyState(title: q.isEmpty ? "No Open Issues" : "No Matches", icon: "smallcircle.circle")
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
