import Charts
import SwiftUI

private struct Pulsing: ViewModifier {
  @Environment(\.accessibilityReduceMotion) private var still

  func body(content: Content) -> some View {
    if still {
      content
    } else {
      content.phaseAnimator([1.0, 0.3]) { view, opacity in
        view.opacity(opacity)
      } animation: { _ in
        .easeInOut(duration: 0.9)
      }
    }
  }
}

extension View {
  func pulsing(_ on: Bool = true) -> some View {
    Group {
      if on { modifier(Pulsing()) } else { self }
    }
  }
}

struct WorkingIcon: View {
  var symbol = "waveform"
  var size: CGFloat = 14

  var body: some View {
    Image(icon: symbol, size: size).foregroundStyle(.green).pulsing()
  }
}

struct StatusLabel: View {
  let title: String
  let symbol: String
  var tint: Color = .secondary
  var spinning = false

  var body: some View {
    Label {
      Text(title)
    } icon: {
      if spinning, !symbol.isEmpty {
        WorkingIcon(symbol: symbol)
      } else if spinning {
        ProgressView().controlSize(.mini)
      } else {
        Image(icon: symbol, size: 14).foregroundStyle(tint)
      }
    }
  }
}

struct EmptyState: View {
  let title: String
  let icon: String
  var detail: String?

  var body: some View {
    ContentUnavailableView {
      Label { Text(title) } icon: { Image(icon: icon, size: 32) }
    } description: {
      if let detail { Text(detail) }
    }
  }
}

struct Meter: View {
  let done: Int
  let total: Int

  var body: some View {
    HStack(spacing: 6) {
      ProgressView(value: Double(done), total: Double(max(total, 1))).controlSize(.small).frame(maxWidth: 60)
      Text("\(done)/\(total)").monospacedDigit().foregroundStyle(.secondary)
    }
  }
}

struct MergeButton: View {
  @Environment(Store.self) private var store
  let pr: PullRequest
  var title = "Merge"
  @State private var confirming = false

  var body: some View {
    if store.mergedNow.contains(pr.number) {
      Text("Merged").foregroundStyle(.secondary)
    } else if store.merging.contains(pr.number) {
      ProgressView().controlSize(.small)
    } else {
      Button(title) { confirming = true }
        .confirmationDialog("Merge #\(pr.number) into main?", isPresented: $confirming) {
          Button("Merge") { store.merge(pr) }
          Button("Cancel", role: .cancel) {}
        } message: {
          Text(pr.oneWay ? "\(pr.tidyTitle)\n\nOne-way door: hard to undo once merged." : pr.tidyTitle)
        }
    }
  }
}

struct BriefText: View {
  let text: String

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(Array(Briefs.blocks(text).enumerated()), id: \.offset) { _, b in
        let body = Briefs.attributed(capitalizedFirst(Briefs.readable(b.text)))
        if let label = b.label {
          Text("\(Text(label).fontWeight(.semibold))  \(Text(body))")
        } else {
          Text(b.bullet ? "•  \(Text(body))" : "\(Text(body))")
        }
      }
    }
    .fixedSize(horizontal: false, vertical: true)
    .textSelection(.enabled)
  }
}

struct DailyCostChart: View {
  let days: [SpendDay]
  var height: CGFloat = 120
  @State private var hover: Date?

  var body: some View {
    let picked = hover.flatMap { h in days.first { Calendar.current.isDate($0.day, inSameDayAs: h) } }
    Chart {
      ForEach(days) { d in
        BarMark(x: .value("Day", d.day, unit: .day), y: .value("Cost", d.cost))
          .foregroundStyle(.tint)
          .opacity(picked == nil || picked?.id == d.id ? 1 : 0.4)
      }
      if let d = picked {
        RuleMark(x: .value("Day", d.day, unit: .day))
          .foregroundStyle(.clear)
          .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
            VStack(alignment: .leading, spacing: 2) {
              Text(d.day, format: .dateTime.weekday(.wide).month().day()).font(.caption).foregroundStyle(.secondary)
              Text(d.cost.usd).font(.headline.monospacedDigit())
              Text("\(d.tokens.compact) tokens · \(plural(d.runs, "run"))").font(.caption).foregroundStyle(.secondary)
            }
            .padding(8)
            .background(.regularMaterial, in: .rect(cornerRadius: 8))
          }
      }
    }
    .chartXSelection(value: $hover)
    .chartXAxis {
      AxisMarks(values: .stride(by: .day)) { _ in
        AxisValueLabel(format: .dateTime.weekday(.abbreviated), centered: true)
      }
    }
    .chartYAxis {
      AxisMarks(values: .automatic(desiredCount: 3)) { value in
        AxisGridLine()
        AxisValueLabel {
          if let v = value.as(Double.self) { Text(v.usdShort) }
        }
      }
    }
    .frame(height: height)
  }
}

struct GoalLine: View {
  let goal: TaskGoal
  let active: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Done when")
      Text(goal.done).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }
    LabeledContent("Goal") {
      Text(status).help(goal.reason ?? "")
    }
  }

  private var status: String {
    let why = goal.reason.map { ": \($0)" } ?? ""
    switch goal.verdict {
    case .met?: return "Met after \(plural(goal.taken, "turn"))"
    case .impossible?: return "Impossible after \(plural(goal.taken, "turn"))\(why)"
    default:
      if !active { return "Ended before it was met\(why)" }
      let turn = "Turn \(min(goal.taken + 1, goal.turns)) of \(goal.turns)"
      return goal.reason.map { "\(turn) · Not yet: \($0)" } ?? turn
    }
  }
}

struct LoopMenu: View {
  @Environment(Store.self) private var store
  let spec: LoopSpec
  var run = true

  var body: some View {
    if run {
      Button("Run Now", systemImage: "play") { store.runNow(spec.name) }
        .disabled(store.running[spec.name] != nil || store.isStarting(spec.name))
      Divider()
    }
    Toggle("Enabled", isOn: store.enabled(spec.name))
      .disabled(store.action != nil)
    Toggle(
      "Notify When It Finishes",
      isOn: Binding(get: { store.notifyAll || store.watched.contains(spec.name) }, set: { _ in store.toggleWatch(spec.name) })
    )
    .disabled(store.notifyAll)
    Button("Edit…", systemImage: "square.and.pencil") { store.editing = .edit(spec) }
    Button("Show SKILL.md", systemImage: "doc.text") { NSWorkspace.shared.open(store.paths.skill(spec.name)) }
    Divider()
    Button("Remove…", systemImage: "trash", role: .destructive) { store.editing = .remove(spec) }
  }
}

struct TaskMenu: View {
  @Environment(Store.self) private var store
  @Environment(\.openURL) private var openURL
  let task: BgTask

  var body: some View {
    Button("Open", systemImage: "arrow.right") { store.page = .task(task.stable) }
    if task.limit != nil {
      Button("Resume Now", systemImage: "play") { store.resumeTask(task) }
        .disabled(store.asking.contains("reply:\(task.id)"))
    }
    if let pr = store.pull(of: task) {
      if pr.open, store.mergeState(pr).mergeable {
        Button("Merge #\(pr.number)", systemImage: "arrow.triangle.merge") { store.merge(pr) }
          .disabled(store.merging.contains(pr.number))
      }
      Button("Open #\(pr.number) on GitHub", systemImage: "safari") { openURL(pr.url) }
    }
    Button("Open in Terminal", systemImage: "terminal") { store.attachTask(task) }
    Divider()
    if task.active {
      Button("Stop", systemImage: "stop", role: .destructive) { store.stopTask(task) }
    } else {
      Button("Remove", systemImage: "trash", role: .destructive) { store.removeTask(task) }
    }
  }
}
