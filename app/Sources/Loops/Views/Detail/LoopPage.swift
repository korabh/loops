import Charts
import SwiftUI

struct LoopPage: View {
  enum Tab: String, CaseIterable, Identifiable {
    case overview, spend, health

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
  }

  @Environment(Store.self) private var store
  @AppStorage("loopTab") private var tab = Tab.overview
  @State private var asked: String?
  let spec: LoopSpec

  var body: some View {
    Group {
      switch tab {
      case .overview: LoopOverview(spec: spec)
      case .spend: LoopSpend(spec: spec)
      case .health: LoopHealth(spec: spec)
      }
    }
    .safeAreaBar(edge: .bottom, spacing: 0) {
      Composer(prompt: "Ask Claude Code about \(spec.title)", busy: asked.map(store.asking.contains) ?? false) { text in
        let key = "loop-ask:\(spec.name):\(Int(Date().timeIntervalSince1970))"
        asked = key
        store.ask(
          "About the loop \(spec.name) (\(spec.title)), whose skill is .claude/skills/\(spec.name)/SKILL.md: \(text)", loop: spec.name, from: key)
      } status: {
        if let asked, let t = store.task(key: asked) {
          HStack(spacing: 6) {
            Text("Claude Code is on it")
            Button("Open") { store.page = .task(t.stable) }.buttonStyle(.link)
          }
        }
      }
    }
    .focusedSceneValue(\.selected, Selected(loops: [spec.name]))
    .navigationTitle(spec.title)
    .navigationSubtitle("\(spec.cadence) · \((store.models[spec.name] ?? "inherit").capitalized)")
    .toolbar {
      ToolbarItem(placement: .principal) {
        Picker("Show", selection: $tab) {
          ForEach(Tab.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
      }
      ToolbarSpacer(.flexible)
      ToolbarItem {
        Button("Run Now", icon: "play") { store.runNow(spec.name) }
          .disabled(store.running[spec.name] != nil || store.isStarting(spec.name))
          .help("Start \(spec.title) now instead of waiting for its next tick")
      }
      ToolbarItem {
        Menu {
          LoopMenu(spec: spec, run: false)
        } label: {
          Label("More", icon: "ellipsis")
        }
        .menuIndicator(.hidden)
      }
    }
  }
}

private struct LoopOverview: View {
  @Environment(Store.self) private var store
  @Environment(\.openURL) private var openURL
  @AppStorage("pullsLoop") private var pullsLoop = ""
  @AppStorage("pullsFilter") private var pullsFilter = PullsPage.Filter.moving
  let spec: LoopSpec

  var body: some View {
    let status = store.loopStatus(spec)
    let waiting = store.items.filter { $0.loops.contains(spec.name) }.count
    let open = store.outcomes.filter { $0.loop == spec.name && !$0.done }
    let runs = RunRow.rows(Array(store.briefs.filter { $0.loop == spec.name }.reversed().prefix(10)), runs: store.perf(spec.name).runs)
    Form {
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
      ScheduleSection(spec: spec)
      if !open.isEmpty {
        Section {
          ForEach(open.prefix(6)) { o in
            LabeledContent {
              StatusLabel(title: o.badge.isEmpty ? o.stage.title : o.badge, symbol: o.stage.symbol, tint: o.stage.tint)
            } label: {
              Text(o.title)
              Text(verbatim: "#\(o.number) · \(o.status)")
            }
            .contentShape(.rect)
            .onTapGesture { openURL(o.url) }
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
      Section("Recent Runs") {
        if runs.isEmpty { Text("No runs yet").foregroundStyle(.secondary) }
        ForEach(runs) { RunDisclosure(row: $0) }
      }
    }
    .formStyle(.grouped)
  }

  private func statusText(_ s: LoopStatus) -> String {
    switch s {
    case .running(let since): "Running for \(Clock.span(store.now.timeIntervalSince(since)))"
    case .resting(let next?): "Resting · next \(Clock.until(next, now: store.now))"
    default: s.title
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

private struct LoopSpend: View {
  @Environment(Store.self) private var store
  let spec: LoopSpec
  @State private var picked: String?

  private static let parts: [(String, Color)] = [
    ("The loop", .accentColor), ("Helpers", .gray), ("Review panel", .gray.opacity(0.6)), ("Judgment", .gray.opacity(0.35)),
  ]

  var body: some View {
    let perf = store.perf(spec.name)
    let all = store.spend.week.cost
    let advice = perf.advice(model: store.models[spec.name] ?? "inherit")
    Form {
      Section("Last 7 Days") {
        LabeledContent("Spent (est.)", value: perf.tokens.spent)
        if all > 0 { LabeledContent("Share of all loops", value: (perf.cost / all).formatted(.percent.precision(.fractionLength(0)))) }
        LabeledContent(
          "Runs",
          value: "\(perf.runs.count) · \(perf.acted.count) did work · \(perf.quiet.count) idle · \(perf.failed.count) failed")
        LabeledContent("A run", value: "\(perf.perRun.usd) · \(perf.runTokens.compact) tokens · \(Clock.span(perf.minutes * 60)) median")
      }
      .redacted(reason: store.spend.loaded ? [] : .placeholder)
      if !perf.runs.isEmpty {
        Section("Runs") {
          chart(perf)
          if let run = perf.runs.first(where: { $0.id == picked }) ?? perf.runs.last { detail(run) }
        }
      }
      Section("Ways to Save") {
        if advice.isEmpty { Text("Nothing to cut this week").foregroundStyle(.secondary) }
        ForEach(advice) { a in
          LabeledContent {
            HStack {
              AdviceStatus(advice: a)
              AdviceButton(advice: a)
            }
          } label: {
            Text(a.title)
            Text(Briefs.attributed(a.detail))
          }
        }
      }
    }
    .formStyle(.grouped)
  }

  private func split(_ run: RunStat) -> [(String, Tokens)] {
    [("The loop", run.main), ("Helpers", run.helpers), ("Review panel", run.panel), ("Judgment", run.judgment)].filter { !$0.1.isEmpty }
  }

  private func chart(_ perf: LoopPerf) -> some View {
    let names = Dictionary(uniqueKeysWithValues: perf.runs.map { ($0.id, Clock.day($0.at, now: store.now)) })
    return Chart {
      ForEach(perf.runs) { run in
        ForEach(split(run), id: \.0) { part in
          BarMark(x: .value("Run", run.id), y: .value("Cost", part.1.cost))
            .foregroundStyle(by: .value("Part", part.0))
            .opacity(picked == nil || picked == run.id ? 1 : 0.5)
        }
      }
    }
    .chartForegroundStyleScale(domain: Self.parts.map(\.0), range: Self.parts.map(\.1))
    .chartLegend(position: .top, alignment: .leading)
    .chartXScale(domain: perf.runs.map(\.id))
    .chartXAxis {
      if perf.runs.count <= 10 {
        AxisMarks { value in
          AxisValueLabel { if let id = value.as(String.self) { Text(names[id] ?? "") } }
        }
      }
    }
    .chartYAxis {
      AxisMarks(values: .automatic(desiredCount: 3)) { value in
        AxisGridLine()
        AxisValueLabel { if let v = value.as(Double.self) { Text(v.usdShort) } }
      }
    }
    .chartXSelection(value: $picked)
    .frame(height: 150)
  }

  @ViewBuilder private func detail(_ run: RunStat) -> some View {
    LabeledContent("Run", value: Clock.day(run.at, now: store.now))
    LabeledContent("Outcome", value: capitalizedFirst(run.outcome))
    LabeledContent(
      "Took",
      value: [Clock.span(run.minutes * 60), plural(run.turns, "turn"), run.reviewers > 0 ? plural(run.reviewers, "reviewer") : nil, run.byHand ? "by you" : nil]
        .compactMap { $0 }.joined(separator: " · "))
    LabeledContent("Spent (est.)", value: run.tokens.spent).help(run.tokens.detail)
    if let brief = run.brief {
      Text(Briefs.attributed(Briefs.first(Brief(id: 0, at: run.at, loop: run.loop, text: brief)))).foregroundStyle(.secondary)
    }
  }
}

private struct LoopHealth: View {
  @Environment(Store.self) private var store
  @Environment(\.openURL) private var openURL
  let spec: LoopSpec
  @State private var picked: Set<String> = []

  private var health: Health { Health.shared }

  var body: some View {
    let h = health.bySkill[spec.name]
    Form {
      Section {
        if let h {
          let s = h.summary
          LabeledContent("Runs", value: "\(s.runs)")
          LabeledContent("Pushback", value: "\(s.pushback)")
          LabeledContent("Interrupted", value: "\(s.interrupts)")
          LabeledContent("Lessons", value: "\(s.lessons)")
          LabeledContent("Problems") {
            Text("\(s.problems)").foregroundStyle(h.problems.contains(where: Health.failing) ? .red : .primary)
          }
          if !h.runs.isEmpty { chart(h) }
        } else if let f = health.failure[spec.name], !health.loading.contains(spec.name) {
          LabeledContent {
            Button("Try Again") { Task { await health.load(spec.name, store: store, force: true) } }
          } label: {
            Text(f).foregroundStyle(.secondary)
          }
        } else {
          HStack {
            ProgressView().controlSize(.small)
            Text("Reading transcripts…").foregroundStyle(.secondary)
            if let at = health.started[spec.name] { Text(at, style: .timer).monospacedDigit().foregroundStyle(.tertiary) }
          }
        }
      } header: {
        Text("Skill Health")
      } footer: {
        Text("Runs count every time the skill was loaded. Pushback and interrupted count runs where the next thing you said pushed back or stopped it.")
      }
      if let h {
        if !h.problems.isEmpty {
          Section("Problems") {
            ForEach(h.problems, id: \.self) { p in
              Label {
                Text(p)
              } icon: {
                Image(icon: Health.failing(p) ? "exclamationmark.triangle" : "exclamationmark.circle", size: 14)
                  .foregroundStyle(Health.failing(p) ? .red : .secondary)
              }
            }
          }
        }
        let flagged = Array(h.runs.filter(\.flagged).prefix(4))
        if !flagged.isEmpty {
          Section("What You Said After It") {
            ForEach(flagged) { r in
              LabeledContent {
                Button("Transcript") { transcript(r) }
              } label: {
                Text(r.said.first.map { "\u{201C}\($0)\u{201D}" } ?? (r.interrupted ? "Stopped it" : "Pushed back"))
                Text("\(r.interrupted ? "Interrupted" : "Pushback") · \(r.date.map { Clock.day($0, now: store.now) } ?? r.at)")
              }
            }
          }
        }
        retro(h)
      }
      if let lessons = store.lessons[spec.name], !lessons.isEmpty {
        Section("Lessons It Keeps") {
          ForEach(Array(lessons.enumerated()), id: \.offset) { _, lesson in
            Text(Briefs.attributed(capitalizedFirst(Briefs.readable(lesson.hasPrefix("- ") ? String(lesson.dropFirst(2)) : lesson))))
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
    }
    .formStyle(.grouped)
    .task(id: spec.name) { await health.load(spec.name, store: store) }
    .onChange(of: store.reportTask(spec.name)?.state) { _, state in reload(state) }
    .onChange(of: store.applyTask(spec.name)?.state) { _, state in reload(state) }
    .onChange(of: h?.retro?.at, initial: true) { _, _ in
      picked = Set((h?.retro?.findings ?? []).filter { $0.file != nil }.map(\.id))
    }
  }

  private func reload(_ state: String?) {
    guard state == "done" || state == "failed" else { return }
    Task { await health.load(spec.name, store: store, force: true) }
  }

  private func transcript(_ r: SkillHealth.Run) {
    store.terminal(["less -S +\(r.line)g '\(r.file.replacingOccurrences(of: "'", with: "'\\''"))'"])
  }

  private func chart(_ h: SkillHealth) -> some View {
    let cal = Calendar.current
    let start = cal.startOfDay(for: store.now.addingTimeInterval(-13 * 86400))
    let end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: store.now)) ?? store.now
    let days = Dictionary(grouping: h.runs.compactMap { r in r.date.flatMap { $0 >= start ? (cal.startOfDay(for: $0), r.flagged) : nil } }) {
      "\($0.0.timeIntervalSince1970)-\($0.1)"
    }
    .map { (day: $0.value[0].0, flagged: $0.value[0].1, count: $0.value.count) }
    .sorted { $0.day < $1.day }
    return Chart(days, id: \.day) { d in
      BarMark(x: .value("Day", d.day, unit: .day), y: .value("Runs", d.count))
        .foregroundStyle(by: .value("Run", d.flagged ? "Flagged" : "Clean"))
    }
    .chartForegroundStyleScale(["Clean": Color.accentColor, "Flagged": Color.orange])
    .chartXScale(domain: start...end)
    .chartXAxis {
      AxisMarks(values: .stride(by: .day, count: 2)) { _ in
        AxisValueLabel(format: .dateTime.weekday(.abbreviated).day(), centered: true)
      }
    }
    .chartLegend(position: .top, alignment: .leading)
    .frame(height: 110)
  }

  @ViewBuilder private func retro(_ h: SkillHealth) -> some View {
    let report = h.retro
    let task = store.reportTask(spec.name).flatMap { $0.active ? $0 : nil }
    let apply = store.applyTask(spec.name)
    Section {
      if let task {
        LabeledContent {
          Button("Open") { store.page = .task(task.stable) }
        } label: {
          Label { Text("Retro running") } icon: { WorkingIcon(symbol: Symbols.askClaude) }
        }
      }
      if let report {
        if !report.summary.isEmpty {
          Text(Briefs.attributed(report.summary)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        ForEach(report.findings) { f in FindingDisclosure(finding: f, applied: report.applied, picked: $picked) }
        if let applied = report.applied {
          LabeledContent {
            if let pr = applied.pr.flatMap(URL.init(string:)) { Button("Open PR") { openURL(pr) } }
          } label: {
            Text("Applied \(applied.ids.count)\(applied.skipped.isEmpty ? "" : " · skipped \(applied.skipped.count)")")
          }
        } else if let apply, apply.active {
          LabeledContent {
            Button("Open") { store.page = .task(apply.stable) }
          } label: {
            Label { Text("Applying the edits") } icon: { WorkingIcon(symbol: Symbols.askClaude) }
          }
        } else {
          let ids = report.findings.filter { $0.file != nil && picked.contains($0.id) }.map(\.id)
          HStack {
            Text("Edits go into one pull request.").foregroundStyle(.secondary)
            Spacer()
            Button("Apply \(ids.count)") { store.startApply(spec.name, ids: ids) }
              .buttonStyle(.borderedProminent)
              .disabled(ids.isEmpty || store.asking.contains("retro-apply:\(spec.name)"))
          }
        }
      }
    } header: {
      HStack {
        Text("Improvements")
        Spacer()
        if task == nil {
          let busy = store.asking.contains("retro-report:\(spec.name)")
          Button(busy ? "Starting…" : report == nil ? "Find Improvements" : "Run Again") { store.startReport(spec.name) }
            .controlSize(.small)
            .disabled(busy)
            .help("Starts a read-only Claude Code retro on this skill in the background")
        }
      }
    } footer: {
      if let at = report?.at { Text(Reader.date(at).map { Clock.ago($0, now: store.now) } ?? at) }
    }
  }
}

private struct FindingDisclosure: View {
  let finding: RetroReport.Finding
  let applied: RetroReport.Applied?
  @Binding var picked: Set<String>
  @State private var open = false

  var body: some View {
    DisclosureGroup(isExpanded: $open) {
      VStack(alignment: .leading, spacing: 6) {
        ForEach(finding.evidence, id: \.self) { e in Text("\u{201C}\(e)\u{201D}").foregroundStyle(.secondary) }
        if let file = finding.file { Text(file).font(.callout.monospaced()).foregroundStyle(.secondary) }
        if finding.old != nil || finding.new != nil {
          VStack(alignment: .leading, spacing: 0) {
            lines(finding.old, "−").foregroundStyle(.red)
            lines(finding.new, "+").foregroundStyle(.green)
          }
          .font(.callout.monospaced())
          .textSelection(.enabled)
        }
      }
      .fixedSize(horizontal: false, vertical: true)
    } label: {
      HStack {
        if let applied {
          Image(icon: applied.ids.contains(finding.id) ? "checkmark.circle" : "minus.circle", size: 14).foregroundStyle(.secondary)
        } else {
          Toggle(finding.title, isOn: Binding(get: { picked.contains(finding.id) }, set: { if $0 { picked.insert(finding.id) } else { picked.remove(finding.id) } }))
            .labelsHidden()
            .disabled(finding.file == nil)
            .help(finding.file == nil ? "Not an edit to the skill" : "Include this edit")
        }
        VStack(alignment: .leading, spacing: 2) {
          Text(Briefs.attributed(finding.title))
          Text("\(capitalizedFirst(finding.severity)) · \(finding.cause)").font(.caption).foregroundStyle(.secondary)
        }
      }
    }
  }

  @ViewBuilder private func lines(_ text: String?, _ mark: String) -> some View {
    if let text {
      ForEach(Array(text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
        Text("\(mark) \(line)")
      }
    }
  }
}
