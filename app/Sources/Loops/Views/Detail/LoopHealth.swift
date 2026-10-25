import Charts
import SwiftUI

struct LoopHealth: View {
  @Environment(Store.self) private var store
  let spec: LoopSpec

  private var health: Health { store.health }

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
        RetroSection(spec: spec, report: h.retro).id(h.retro?.at)
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
}

private struct RetroSection: View {
  @Environment(Store.self) private var store
  @Environment(\.openURL) private var openURL
  let spec: LoopSpec
  let report: RetroReport?
  @State private var picked: Set<String>

  init(spec: LoopSpec, report: RetroReport?) {
    self.spec = spec
    self.report = report
    _picked = State(initialValue: Set((report?.findings ?? []).filter { $0.file != nil }.map(\.id)))
  }

  var body: some View {
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
            .accessibilityLabel(applied.ids.contains(finding.id) ? "Applied" : "Not applied")
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
