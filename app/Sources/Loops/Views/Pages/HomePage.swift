import SwiftUI

struct HomePage: View {
  @Environment(Store.self) private var store
  @AppStorage("catchUpShown") private var catchUp = false
  @AppStorage("pullsFilter") private var pullsFilter = PullsPage.Filter.moving

  var body: some View {
    Form {
      if !store.phase.healthy, store.phase != .unknown || store.runnerProblem != nil { RunnerSection() }
      NeedsYouSection(open: open) {
        EmptyView()
      } header: {
        Text("Needs You")
      } footer: { count in
        if count > 0 {
          Button("Show All \(count)") { store.page = .inbox }.buttonStyle(.link)
        }
      }
      RunningSection()
      WeekSection()
      UpNextSection()
    }
    .formStyle(.grouped)
    .pageTitle("Home")
    .toolbar {
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
      if actionable {
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

  private var actionable: Bool {
    if store.action != nil { return true }
    switch store.phase {
    case .stopped, .limited, .blocked: return true
    default: return false
    }
  }
}

private struct RunningSection: View {
  @Environment(Store.self) private var store

  var body: some View {
    let tasks = store.tasks.filter { store.phase($0) == .working }
    Section("Running Now") {
      if store.running.isEmpty && tasks.isEmpty {
        Text("Nothing running").foregroundStyle(.secondary)
      }
      RunningLoops { store.page = .loop($0) }
      ForEach(tasks, id: \.stable) { t in
        let job = store.jobs.jobs[t.id]
        Button {
          store.page = .task(t.stable)
        } label: {
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
        }
        .buttonStyle(.plain)
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

private struct UpNextSection: View {
  @Environment(Store.self) private var store

  var body: some View {
    Section("Up Next") {
      if store.forecast.isEmpty {
        Text("Nothing scheduled").foregroundStyle(.secondary)
      }
      ForEach(store.forecast.prefix(3)) { tick in
        LabeledContent(joined(tick.runs.map(\.title)), value: Clock.day(tick.at, now: store.now))
      }
    }
  }
}
