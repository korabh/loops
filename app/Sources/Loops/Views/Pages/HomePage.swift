import SwiftUI

struct HomePage: View {
  @Environment(Store.self) private var store
  @AppStorage("catchUpShown") private var catchUp = false
  @AppStorage("pullsFilter") private var pullsFilter = PullsPage.Filter.moving

  var body: some View {
    let inbox = store.inbox
    let pulls = Array(store.pulls.values)
    let shares = Attention.shares(inbox: inbox, pulls: pulls)
    let waits = store.waits(inbox)
    let loops = shares.first { $0.holder == .loops }?.count ?? 0
    let loaded = store.githubLoaded || !store.pulls.isEmpty
    Form {
      if !store.phase.healthy { RunnerSection() }
      Section {
        NeedsYouSummary(
          waiting: inbox.count, merged: Attention.merged(pulls, now: store.now), shares: loaded ? shares.filter { $0.count > 0 } : [],
          sentence: Attention.sentence(counts: Attention.counts(inbox), loops: loops, oldest: waits.first.map { ($0.name, $0.seconds) }),
          open: open
        )
        .redacted(reason: loaded ? [] : .placeholder)
        if loaded, !waits.isEmpty {
          WaitTimeline(waits: waits, now: store.now, open: open)
        }
      } header: {
        Text("Needs You")
      } footer: {
        if !inbox.isEmpty {
          Button("Show All \(inbox.count)") { store.page = .inbox }.buttonStyle(.link)
        }
      }
      RunningSection()
      WeekSection()
      Section("Up Next") {
        if store.forecast.isEmpty {
          Text("Nothing scheduled").foregroundStyle(.secondary)
        }
        ForEach(store.forecast.prefix(3)) { tick in
          LabeledContent(joined(tick.runs.map(\.title)), value: Clock.day(tick.at, now: store.now))
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Home")
    .toolbar {
      ToolbarSpacer(.flexible)
      ToolbarItem {
        Button("New Task…", icon: "plus") { store.composing = true }
          .help("Start a Claude Code task in the background")
      }
      ToolbarItem {
        Button("Catch Up", icon: "clock.arrow.circlepath") { catchUp.toggle() }
          .help("What happened while you were away")
      }
    }
    .inspector(isPresented: $catchUp) {
      CatchUpView().inspectorColumnWidth(min: 300, ideal: 360, max: 520)
    }
  }

  private func open(_ id: String) {
    store.inboxSelection = id
    store.page = .inbox
  }

  private func open(_ share: Share) {
    if let id = share.first {
      open(id)
    } else {
      pullsFilter = .moving
      store.page = .pulls
    }
  }
}

private struct RunnerSection: View {
  @Environment(Store.self) private var store

  var body: some View {
    let limit = store.limit
    let reset = (limit?.resets.map { $0 <= store.now } ?? false) || store.limitLifted
    let others = (store.runner?.accounts ?? []).filter { $0.dir != store.runner?.account && $0.email != nil && store.rested($0) }
    Section {
      Label {
        VStack(alignment: .leading, spacing: 2) {
          Text(store.headline).font(.headline)
          Text(store.sentence).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
      } icon: {
        Image(icon: store.phase.symbol).foregroundStyle(store.phase.tint)
      }
      if store.phase == .limited, !reset, let at = limit?.at, let resets = limit?.resets, resets > at {
        ProgressView(timerInterval: at...resets, countsDown: false) {
          Text("Resets \(Clock.day(resets, now: store.now))")
        }
      }
      if let problem = store.runnerProblem, store.phase == .unknown {
        Text(problem).foregroundStyle(.secondary)
      }
      HStack {
        if let action = store.action {
          ProgressView().controlSize(.small)
          Text(action).foregroundStyle(.secondary)
        }
        Spacer()
        switch store.phase {
        case .stopped:
          Button("Start Runner") { store.perform("Starting…", ["start"]) }.buttonStyle(.borderedProminent)
        case .limited:
          Button("Add Account…") { store.addAccount() }
          if reset {
            Button("Resume Now") { store.resume() }.buttonStyle(.borderedProminent)
          } else if let next = others.first, let email = next.email {
            Button("Switch to \(email)") { store.perform("Moving…", ["account", "use", next.dir]) }.buttonStyle(.borderedProminent)
          }
        case .blocked:
          Button("Open in Terminal") { store.attach() }
          Button("Resume Now") { store.resume() }.buttonStyle(.borderedProminent)
        default:
          EmptyView()
        }
      }
      .disabled(store.action != nil)
    }
  }
}

private struct RunningSection: View {
  @Environment(Store.self) private var store

  var body: some View {
    let loops = store.running.sorted { $0.value < $1.value }
    let tasks = store.tasks.filter { store.phase($0) == .working }
    Section {
      if loops.isEmpty && tasks.isEmpty {
        Text("Nothing running").foregroundStyle(.secondary)
      }
      ForEach(loops, id: \.key) { name, started in
        LabeledContent {
          Text(Clock.short(store.now.timeIntervalSince(started))).monospacedDigit()
        } label: {
          Label {
            Text(store.title(name))
            if let step = store.liveStep(name) { Text(step).lineLimit(1) }
          } icon: {
            WorkingIcon(symbol: Symbols.loop(name), size: 16)
          }
        }
        .contentShape(.rect)
        .onTapGesture { store.page = .loop(name) }
      }
      ForEach(tasks, id: \.stable) { t in
        let job = store.jobs.jobs[t.id]
        LabeledContent {
          if let job, job.tasksTotal > 0 {
            ProgressView(value: Double(job.tasksDone), total: Double(job.tasksTotal)).frame(width: 80)
          } else {
            Text(Clock.short(store.now.timeIntervalSince(t.started))).monospacedDigit()
          }
        } label: {
          Label {
            Text(Store.short(t)).lineLimit(1)
            Text(job?.current ?? job?.activity.last ?? t.recent.last ?? "Starting").lineLimit(1)
          } icon: {
            WorkingIcon(symbol: Symbols.askClaude, size: 16)
          }
        }
        .contentShape(.rect)
        .onTapGesture { store.page = .task(t.stable) }
      }
    } header: {
      Text("Running Now")
    } footer: {
      if let tick = store.forecast.first {
        Text("Next tick at \(Clock.time(tick.at)): \(joined(tick.runs.map(\.title)))")
      }
    }
  }
}

private struct WeekSection: View {
  @Environment(Store.self) private var store

  var body: some View {
    let s = store.spend
    let done = s.runs.filter(\.finished)
    Section {
      DailyCostChart(days: SpendDay.days(s.runs, now: store.now))
      LabeledContent("Spent (est.)", value: s.week.spent)
      LabeledContent("Today", value: s.today.spent)
      LabeledContent(
        "Runs",
        value: "\(s.runs.count) · \(done.filter { $0.acted && !$0.failed }.count) did work · \(done.filter { $0.failed && !$0.limited }.count) failed")
    } header: {
      Text("This Week")
    } footer: {
      Button("Show Spend") { store.page = .spend }.buttonStyle(.link)
    }
    .redacted(reason: s.loaded ? [] : .placeholder)
  }
}

struct InboxLine: View {
  let row: InboxRow
  let open: () -> Void

  var body: some View {
    LabeledContent {
      InboxAction(row: row, open: open)
    } label: {
      Label {
        VStack(alignment: .leading, spacing: 2) {
          Text(Briefs.attributed(row.title)).lineLimit(2)
          if !row.detail.isEmpty {
            Text(row.detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
          }
        }
      } icon: {
        Image(icon: row.kind.symbol).foregroundStyle(row.kind.tint)
      }
    }
  }
}

struct InboxAction: View {
  @Environment(Store.self) private var store
  let row: InboxRow
  let open: () -> Void

  var body: some View {
    switch row.source {
    case .task:
      Button("Answer", action: open)
    case .item(let item):
      if let pr = item.pr {
        if store.mergeState(pr).mergeable {
          MergeButton(pr: pr)
        } else if store.asking.contains(item.id) {
          ProgressView().controlSize(.small)
        } else if store.started[item.id] != nil {
          Text("Started").foregroundStyle(.secondary)
        } else {
          Button("Fix") { store.askClaude(item, fix: true) }
            .help("Ask Claude Code to fix what blocks it")
        }
      } else {
        Button("Reply", action: open)
      }
    case .problem(let p):
      if CI.shared.busy(p) {
        ProgressView().controlSize(.small)
      } else if let action = p.action {
        Button(action) { CI.shared.perform(p, store: store) }
      }
    }
  }
}

private struct CatchUpView: View {
  @Environment(Store.self) private var store
  @AppStorage("recallScope") private var scope = RecallScope.away
  @State private var topic = ""

  private var recall: Recall { .shared }

  var body: some View {
    Form {
      Section {
        Picker("Since", selection: $scope) {
          ForEach(RecallScope.allCases) { Text($0.title).tag($0) }
        }
        TextField("Topic", text: $topic, prompt: Text("Any loop, PR or area"))
          .onSubmit { recall.run(scope, topic: topic, store: store) }
        HStack {
          if let started = recall.started {
            ProgressView().controlSize(.small)
            Text("Reading sessions, briefs and PRs").foregroundStyle(.secondary)
            Text(started, style: .timer).monospacedDigit().foregroundStyle(.tertiary)
          }
          Spacer()
          Button("Catch Me Up") { recall.run(scope, topic: topic, store: store) }
            .buttonStyle(.borderedProminent)
            .disabled(recall.running)
        }
      } header: {
        Text("Catch Up")
      } footer: {
        Text("A read-only Claude Code run on Sonnet, capped at $3.")
      }
      if let failure = recall.failure {
        Section { Label(failure, icon: "exclamationmark.triangle").foregroundStyle(.red) }
      }
      if let b = recall.brief {
        Section {
          ForEach(Array(b.capsule.enumerated()), id: \.offset) { _, line in
            Text(Briefs.attributed(line)).fixedSize(horizontal: false, vertical: true)
          }
        } header: {
          Text("As of \(Clock.day(b.at, now: store.now)) · \(b.window)")
        }
        if !b.threads.isEmpty {
          Section("Threads") {
            ForEach(b.threads) { ThreadLine(thread: $0) }
          }
        }
        if !b.problems.isEmpty {
          Section("Problems") {
            ForEach(b.problems) { p in
              LabeledContent {
                Button("Fix") {
                  store.ask("Look into this recurring problem and fix its root cause, or say why it should stay: \(p.text)", loop: nil)
                }
              } label: {
                Text(Briefs.attributed(p.text))
              }
            }
          }
        }
        Section("Next") {
          LabeledContent {
            if let n = b.next.pr, let url = store.pullURL(n) {
              Button("Open #\(n)") { NSWorkspace.shared.open(url) }
            } else if let prompt = b.next.prompt {
              Button("Start") { store.ask(prompt, loop: nil) }
                .disabled(store.asking.contains(prompt))
            }
          } label: {
            Text(Briefs.attributed(b.next.text))
          }
        }
      }
    }
    .formStyle(.grouped)
  }
}

private struct ThreadLine: View {
  @Environment(Store.self) private var store
  let thread: RecallBrief.Thread

  private var look: (title: String, symbol: String, tint: Color) {
    switch thread.status {
    case "merged": ("Merged", "arrow.triangle.merge", .purple)
    case "open": ("Open", "arrow.triangle.pull", .green)
    case "inflight": ("In flight", "circle.dotted", .orange)
    case "verified": ("Verified", "checkmark.circle", .green)
    case "reverted": ("Reverted", "arrow.uturn.backward", .red)
    default: ("Planned", "circle", .secondary)
    }
  }

  var body: some View {
    let pull = thread.pr.flatMap { store.pulls[$0] }
    LabeledContent {
      if thread.status == "open", let pull, pull.open, store.mergeState(pull).mergeable {
        MergeButton(pr: pull)
      } else if thread.status == "reverted", let n = thread.pr {
        Button("Ask Why") {
          store.ask("Use the why skill: why was #\(n) reverted, and what would make the next attempt hold? It was: \(thread.title)", loop: nil)
        }
      } else if thread.status == "planned" {
        Button("Start") { store.ask(thread.title, loop: nil, done: Goal.pullRequest) }
          .disabled(store.asking.contains(thread.title))
      } else if let n = thread.pr, let url = store.pullURL(n) {
        Button("#\(n)") { NSWorkspace.shared.open(url) }.buttonStyle(.link)
      }
    } label: {
      Label {
        Text(Briefs.attributed(thread.title))
        Text(look.title)
      } icon: {
        Image(icon: look.symbol, size: 14).foregroundStyle(look.tint)
      }
    }
  }
}
