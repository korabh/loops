import SwiftUI

struct TaskPage: View {
  @Environment(Store.self) private var store
  @Environment(\.openURL) private var openURL
  let task: BgTask
  @State private var full = false

  var body: some View {
    let phase = store.phase(task)
    let job = store.jobs.jobs[task.id]
    let plan = job?.plan ?? []
    let agents = store.subAgents(task)
    Form {
      Section {
        Text(task.prompt)
          .lineLimit(full ? nil : 6)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
        if task.prompt.count > 400 || task.prompt.split(separator: "\n").count > 6 {
          Button(full ? "Show Less" : "Show More") { full.toggle() }.buttonStyle(.link)
        }
      } header: {
        Text("Prompt")
      }
      Section {
        LabeledContent("Status") {
          StatusLabel(title: store.status(task, phase), symbol: phase.symbol, tint: phase.tint, spinning: phase == .working)
        }
        if let loop = task.loop {
          LabeledContent("Loop") {
            Button(store.title(loop)) { store.page = .loop(loop) }.buttonStyle(.link)
          }
        }
        LabeledContent("Started", value: Clock.day(task.started, now: store.now))
        if let spent = store.taskSpend(task) { LabeledContent("Spent (est.)", value: spent.spent).help(spent.detail) }
        if let goal = task.goal { GoalLine(goal: goal, active: task.active || task.limit != nil) }
      }
      if phase == .working {
        Section("Now") {
          LabeledContent("Step") {
            Text(job?.current ?? job?.detail ?? job?.activity.last ?? task.recent.last ?? "Starting").multilineTextAlignment(.trailing)
          }
          if let finish = store.finishes(task, plan: plan, now: store.now) {
            LabeledContent("Time left") { TimeLeft(finish: finish, now: store.now) }
          }
          ForEach(Array((job?.activity ?? task.recent).dropLast().suffix(4).reversed().enumerated()), id: \.offset) { _, step in
            Text(step).foregroundStyle(.secondary).lineLimit(1)
          }
        }
      }
      if !plan.isEmpty { PlanSection(task: task, plan: plan) }
      if !agents.isEmpty { AgentsSection(agents: agents) }
      if phase == .needsYou {
        Section("Your Answer") { AnswerForm(task: task) }
      }
      if let limit = task.limit {
        Section {
          LabeledContent {
            if store.asking.contains("reply:\(task.id)") {
              ProgressView().controlSize(.small)
            } else {
              Button("Resume Now") { store.resumeTask(task) }
            }
          } label: {
            Text("Stopped by the \(limit.kind)")
            Text(limit.resets.map { $0 > store.now ? "It resumes on its own at \(Clock.day($0, now: store.now))" : "Resuming" } ?? limit.text)
          }
        }
      }
      if let answer = task.answer, phase != .needsYou, !task.running {
        Section(phase == .failed ? "Ended" : "Answer") {
          Text(Briefs.attributed(answer)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
      }
      if let pr = store.pull(of: task) {
        Section("Pull Request") {
          LabeledContent {
            HStack {
              Button("Open") { openURL(pr.url) }
              if pr.open, store.mergeState(pr).mergeable { MergeButton(pr: pr).buttonStyle(.borderedProminent) }
            }
          } label: {
            Text(pr.tidyTitle)
            Text(verbatim: "#\(pr.number) · \(store.mergeState(pr).title)")
          }
        }
      }
      Section {
        if let file = store.transcript(task) {
          LabeledContent("Transcript") {
            Button(file.lastPathComponent) { NSWorkspace.shared.open(file) }.buttonStyle(.link)
          }
        }
        if let cwd = task.cwd {
          LabeledContent("Worktree") {
            Button((cwd as NSString).lastPathComponent) { NSWorkspace.shared.open(URL(fileURLWithPath: cwd)) }.buttonStyle(.link)
          }
        }
      }
    }
    .formStyle(.grouped)
    .safeAreaBar(edge: .bottom, spacing: 0) { composer(phase, job) }
    .focusedSceneValue(\.selected, Selected(urls: store.pull(of: task).map { [$0.url] } ?? [], pulls: store.pull(of: task).map { [$0] } ?? [], tasks: [task]))
    .navigationTitle(Store.short(task))
    .navigationSubtitle(store.kind(of: task))
    .toolbar {
      ToolbarSpacer(.flexible)
      ToolbarItem {
        Button("Open in Terminal", icon: "terminal") { store.attachTask(task) }
      }
      ToolbarItem {
        if task.active {
          Button("Stop", icon: "stop", role: .destructive) { store.stopTask(task) }
        } else {
          Button("Remove", icon: "trash", role: .destructive) {
            store.removeTask(task)
            store.page = .tasks
          }
        }
      }
    }
    .onAppear { store.jobs.follow(task.id) }
    .onDisappear { store.jobs.follow(nil) }
  }

  private func composer(_ phase: TaskPhase, _ job: Job?) -> some View {
    let working = phase == .working
    let sending = store.asking.contains("reply:\(task.id)")
    return Composer(
      prompt: working ? "Queue a follow-up for when Claude stops" : phase == .needsYou ? "Answer, or follow up" : "Follow up",
      send: working ? "Queue" : "Send", icon: working ? "clock" : "arrow.up", busy: sending,
      more: working ? [ComposerAction(title: "Stop and Send Now") { store.reply(task, $0) }] : [],
      submit: { text in
        if working { store.queue(task, text) } else { store.reply(task, text) }
      }
    ) {
      if sending {
        Text("Sending…")
      } else if let q = store.queued[task.stable] {
        HStack(spacing: 6) {
          Image(icon: "clock", size: 12)
          Text("Sends when Claude stops: \(q)")
          Button("Cancel") { store.unqueue(task) }.buttonStyle(.link)
        }
      } else if working {
        HStack(spacing: 6) {
          WorkingIcon(symbol: Symbols.askClaude, size: 12)
          Text(job?.current ?? job?.activity.last ?? task.recent.last ?? "Working")
        }
      }
    }
  }
}
