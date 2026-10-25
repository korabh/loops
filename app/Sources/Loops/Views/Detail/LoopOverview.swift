import SwiftUI

struct LoopOverview: View {
  let spec: LoopSpec

  var body: some View {
    Form {
      LoopStatusSection(spec: spec)
      ScheduleSection(spec: spec)
      OpenPullsSection(spec: spec)
      RecentRunsSection(spec: spec)
    }
    .formStyle(.grouped)
  }
}

private struct LoopStatusSection: View {
  @Environment(Store.self) private var store
  let spec: LoopSpec

  var body: some View {
    let status = store.loopStatus(spec)
    let waiting = store.items.filter { $0.loops.contains(spec.name) }.count
    Section {
      if let d = store.descriptions[spec.name] {
        Text(d).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      LabeledContent("Status") {
        StatusLabel(title: statusText(status), symbol: status.symbol, tint: status.tint, spinning: status.active)
      }
      if status == .off {
        LabeledContent {
          Button("Enable") { store.setEnabled(spec.name, true) }.disabled(store.action != nil)
        } label: {
          Text("Disabled")
          Text("The runner skips it until you enable it")
        }
      }
      if case .running = status {
        LiveRows(loop: spec.name)
      } else {
        LabeledContent("Last run", value: store.states[spec.name]?.at.map { Clock.day($0, now: store.now) } ?? "Never")
        LabeledContent("Next run", value: store.nextRun[spec.name].map { "\(Clock.day($0, now: store.now)) · \(Clock.until($0, now: store.now))" } ?? "–")
        ForEach(Array((store.nextUp[spec.name] ?? []).prefix(3).enumerated()), id: \.offset) { i, line in
          LabeledContent(i == 0 ? "Next up" : "") {
            Text(Briefs.attributed(capitalizedFirst(Briefs.readable(line)))).multilineTextAlignment(.trailing)
          }
        }
      }
      if waiting > 0 {
        LabeledContent("Needs you") {
          Button(plural(waiting, "item")) { store.page = .inbox }.buttonStyle(.link)
        }
      }
    }
  }

  private func statusText(_ s: LoopStatus) -> String {
    switch s {
    case .running(let since): "Running for \(Clock.span(store.now.timeIntervalSince(since)))"
    case .resting(let next?): "Resting · next \(Clock.until(next, now: store.now))"
    default: s.title
    }
  }
}

private struct OpenPullsSection: View {
  @Environment(Store.self) private var store
  @Environment(\.openURL) private var openURL
  @AppStorage("pullsLoop") private var pullsLoop = ""
  @AppStorage("pullsFilter") private var pullsFilter = PullsPage.Filter.moving
  let spec: LoopSpec

  var body: some View {
    let open = store.outcomes.filter { $0.loop == spec.name && !$0.done }
    if !open.isEmpty {
      Section {
        ForEach(open.prefix(6)) { o in
          Button {
            openURL(o.url)
          } label: {
            LabeledContent {
              StatusLabel(title: o.badge.isEmpty ? o.stage.title : o.badge, symbol: o.stage.symbol, tint: o.stage.tint)
            } label: {
              Text(o.title)
              Text(verbatim: "#\(o.number) · \(o.status)")
            }
            .contentShape(.rect)
          }
          .buttonStyle(.plain)
          .contextMenu { PullMenu(outcome: o) }
        }
      } header: {
        Text("Open Pull Requests")
      } footer: {
        if open.count > 6 {
          Button("Show All \(open.count)") {
            pullsLoop = spec.name
            pullsFilter = .all
            store.page = .pulls
          }
          .buttonStyle(.link)
        }
      }
    }
  }
}

private struct RecentRunsSection: View {
  @Environment(Store.self) private var store
  let spec: LoopSpec

  var body: some View {
    let runs = RunRow.rows(Array(store.briefs.filter { $0.loop == spec.name }.reversed().prefix(10)), runs: store.perf(spec.name).runs)
    Section("Recent Runs") {
      if runs.isEmpty { Text("No runs yet").foregroundStyle(.secondary) }
      ForEach(runs) { RunDisclosure(row: $0) }
    }
  }
}

private struct LiveRows: View {
  @Environment(Store.self) private var store
  let loop: String

  var body: some View {
    let agents = store.live?.agents(for: loop) ?? []
    let active = agents.filter { !$0.finished && !$0.stalled }
    let focus = active.last ?? agents.last
    let reviewers = agents.filter { $0.role?.hasSuffix("reviewer") == true }
    let spent = agents.map(\.tokens).reduce(Tokens(), +)
    if let focus {
      LabeledContent("Now") {
        Text(focus.stalled ? "No activity for \(Clock.span(store.now.timeIntervalSince(focus.lastAt ?? store.now)))" : focus.current ?? "Starting")
          .foregroundStyle(focus.stalled ? .red : .primary)
          .multilineTextAlignment(.trailing)
      }
      ForEach(focus.recent.dropLast().suffix(4).reversed()) { step in
        LabeledContent(step.at.map(Clock.time) ?? "") {
          Text(step.text).foregroundStyle(.secondary).lineLimit(1)
        }
      }
    }
    if !reviewers.isEmpty {
      LabeledContent("Review panel", value: "\(reviewers.filter(\.finished).count) of \(reviewers.count) done")
    }
    if !spent.isEmpty {
      LabeledContent("So far (est.)", value: spent.spent)
    }
  }
}

private struct ScheduleSection: View {
  @Environment(Store.self) private var store
  @Environment(\.openURL) private var openURL
  let spec: LoopSpec

  var body: some View {
    let model = store.models[spec.name] ?? "inherit"
    let hours = spec.from.flatMap { f in spec.until.map { [f, $0] } }
    Section {
      Picker("Runs", selection: Binding(get: { spec.every }, set: { if $0 != spec.every { store.proposed = .every(spec, $0) } })) {
        ForEach(Set(LoopChange.cadences + [spec.every]).sorted(), id: \.self) { Text(LoopSpec.cadence($0)).tag($0) }
      }
      Picker("Hours", selection: Binding(get: { hours }, set: { if $0 != hours { store.proposed = .hours(spec, $0) } })) {
        Text("Any time").tag(nil as [Int]?)
        ForEach(LoopChange.windows + (hours.map { LoopChange.windows.contains($0) ? [] : [$0] } ?? []), id: \.self) { w in
          Text(String(format: "%02d:00–%02d:00", w[0], w[1])).tag(Optional(w))
        }
      }
      Picker("Model", selection: Binding(get: { model }, set: { if $0 != model { store.proposed = .model(spec, $0) } })) {
        ForEach(ClaudeApp.models + (ClaudeApp.models.contains(model) ? [] : [model]), id: \.self) { Text($0.capitalized).tag($0) }
      }
      if spec.alone { LabeledContent("Runs alone", value: "After the other loops of its tick") }
    } header: {
      Text("Schedule")
    } footer: {
      if let c = store.changes[spec.name] {
        if c.working {
          HStack {
            ProgressView().controlSize(.small)
            Text("Opening a pull request to \(c.change.label)…")
          }
        } else if let url = c.opened {
          HStack {
            Text("Pull request opened to \(c.change.label).")
            Button("View on GitHub") { openURL(url) }.buttonStyle(.link)
          }
        } else if let f = c.failure {
          Text(f).foregroundStyle(.red)
        }
      } else {
        Text("Changes open a pull request and apply once it merges.")
      }
    }
  }
}

private struct RunDisclosure: View {
  @Environment(Store.self) private var store
  let row: RunRow
  @State private var open = false

  var body: some View {
    let o = row.outcome
    DisclosureGroup(isExpanded: $open) {
      BriefText(text: Briefs.body(row.brief))
    } label: {
      LabeledContent {
        Text(row.run.map { $0.tokens.spent } ?? "").monospacedDigit()
      } label: {
        Label {
          Text(Briefs.attributed(Briefs.first(row.brief))).lineLimit(open ? nil : 1)
          Text("\(o.title) · \(Clock.day(row.brief.at, now: store.now))")
        } icon: {
          Image(icon: o.symbol, size: 14).foregroundStyle(o.tint)
        }
      }
    }
  }
}
