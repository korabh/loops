import SwiftUI

struct AdviceStatus: View {
  @Environment(Store.self) private var store
  let advice: Advice

  var body: some View {
    if let task = store.adviceTask(advice) {
      let phase = store.phase(task)
      StatusLabel(title: store.status(task, phase), symbol: "asterisk", tint: phase.tint, spinning: phase == .working)
    } else if case .model(let m)? = advice.action, let loop = advice.loop {
      if let found = store.modelPR(loop, model: m) {
        StatusLabel(
          title: found.pull?.merged == true ? "Merged" : "PR #\(found.pr.number) open", symbol: "arrow.triangle.pull",
          tint: found.pull?.merged == true ? .purple : .green)
      } else if let c = store.changes[loop], c.change.model == m {
        if c.working {
          StatusLabel(title: "Opening PR", symbol: "", spinning: true)
        } else if let f = c.failure {
          StatusLabel(title: "Failed", symbol: "xmark.circle", tint: .red).help(f)
        }
      } else {
        Text("Suggested").foregroundStyle(.secondary)
      }
    } else {
      Text("Suggested").foregroundStyle(.secondary)
    }
  }
}

struct AdviceButton: View {
  @Environment(Store.self) private var store
  @Environment(\.openURL) private var openURL
  let advice: Advice

  var body: some View {
    switch advice.action {
    case .ask(let label, let prompt, let done)?:
      if let task = store.adviceTask(advice) {
        Button("Open") { store.page = .task(task.stable) }
      } else {
        let key = "advice:\(advice.id)"
        Button(store.asking.contains(key) ? "Starting…" : "Ask Claude") { store.ask(prompt, loop: advice.loop, from: key, done: done) }
          .disabled(store.asking.contains(key))
          .help(label)
      }
    case .model(let model)?:
      if let loop = advice.loop {
        if let found = store.modelPR(loop, model: model) {
          Button("View PR") { openURL(found.pr.url) }
        } else if let spec = store.specs.first(where: { $0.name == loop }) {
          Button("Switch to \(model.capitalized)…") { store.proposed = .model(spec, model) }
            .disabled(store.changes[loop]?.working == true)
        }
      }
    case .retro?:
      if let task = store.adviceTask(advice) {
        Button("Open") { store.page = .task(task.stable) }
      } else if let loop = advice.loop {
        let busy = store.asking.contains("retro-report:\(loop)")
        Button(busy ? "Starting…" : "Run Retro") { store.startReport(loop) }
          .disabled(busy)
          .help("A read-only Claude Code retro on this skill")
      }
    case nil:
      EmptyView()
    }
  }
}

extension Store {
  func actTitle(_ a: Advice) -> String {
    if adviceTask(a) != nil { return "Open Task" }
    switch a.action {
    case .ask?: return "Ask Claude"
    case .model(let m)?: return a.loop.flatMap { modelPR($0, model: m) } == nil ? "Switch to \(m.capitalized)…" : "View Pull Request"
    case .retro?: return "Run Retro"
    case nil: return "Show Details"
    }
  }

  func act(_ a: Advice) {
    if let t = adviceTask(a) {
      page = .task(t.stable)
      return
    }
    switch a.action {
    case .ask(_, let prompt, let done)?:
      let key = "advice:\(a.id)"
      guard !asking.contains(key) else { return }
      ask(prompt, loop: a.loop, from: key, done: done)
    case .model(let m)?:
      guard let loop = a.loop else { return }
      if let found = modelPR(loop, model: m) {
        NSWorkspace.shared.open(found.pr.url)
      } else if let spec = specs.first(where: { $0.name == loop }), changes[loop]?.working != true {
        proposed = .model(spec, m)
      }
    case .retro?:
      guard let loop = a.loop, !asking.contains("retro-report:\(loop)") else { return }
      startReport(loop)
    case nil:
      break
    }
  }

  func adviceTask(_ a: Advice) -> BgTask? {
    switch a.action {
    case .ask?: task(key: "advice:\(a.id)")
    case .retro?: a.loop.flatMap { reportTask($0) }.flatMap { $0.active ? $0 : nil }
    default: nil
    }
  }
}
