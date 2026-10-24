import SwiftUI

struct NewTaskSheet: View {
  @Environment(Store.self) private var store
  @Environment(\.dismiss) private var dismiss
  @AppStorage("newTaskGoal") private var goal = true
  @FocusState private var focused: Bool

  private var draft: GoalDraft { GoalDraft.shared }
  private var ideas: GoalIdeas { GoalIdeas.shared }

  private var trimmed: String { draft.task.trimmingCharacters(in: .whitespacesAndNewlines) }
  private var over: Int { Goal.condition(draft.task, done: draft.done, turns: draft.turns).count - Goal.limit }

  private var valid: Bool {
    !trimmed.isEmpty && (!goal || (!draft.done.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && over <= 0))
  }

  var body: some View {
    @Bindable var draft = draft
    VStack(alignment: .leading, spacing: 0) {
      Text("New Task").font(.headline).padding(.horizontal, 20).padding(.top, 16)
      Form {
        Section {
          TextField("Task", text: $draft.task, prompt: Text("What should Claude Code get done?"), axis: .vertical)
            .lineLimit(3...8)
            .labelsHidden()
            .focused($focused)
          Picker("Loop", selection: Binding(get: { draft.loop ?? "" }, set: { draft.loop = $0.isEmpty ? nil : $0 })) {
            Text("None").tag("")
            Divider()
            ForEach(store.specs) { Text($0.title).tag($0.name) }
          }
          Toggle("Keep going until it's done", isOn: $goal)
        } footer: {
          Text("Runs Claude Code in the background in its own worktree, in auto mode.")
        }
        if goal {
          Section {
            TextField("Done when", text: $draft.done, prompt: Text("Done when a command exits 0, or Claude prints a number"), axis: .vertical)
              .lineLimit(1...4)
              .labelsHidden()
            if draft.done.isEmpty, let suggested = ideas.dones[trimmed] {
              LabeledContent {
                Button("Use") { draft.done = suggested }
              } label: {
                Text("Suggested")
                Text(suggested)
              }
            }
            Picker("Turns", selection: $draft.turns) {
              ForEach(Array(Set([5, 10, 15, 20, 30, 40, 60, draft.turns])).sorted(), id: \.self) { Text("\($0)").tag($0) }
            }
            if over > 0 {
              Text("\(over) characters over the 4,000 limit").foregroundStyle(.red)
            }
          } header: {
            HStack {
              Text("Goal")
              Spacer()
              if ideas.writing == trimmed {
                ProgressView().controlSize(.small)
              } else {
                Button("Suggest a Check") { Task { await ideas.suggestDone(for: trimmed, store: store) } }
                  .controlSize(.small)
                  .disabled(trimmed.count < 15)
              }
            }
          } footer: {
            Text("A separate check judges the goal after every turn; past the turn limit it ends as impossible.")
          }
        }
        Section {
          if ideas.busy {
            HStack {
              ProgressView().controlSize(.small)
              Text("Finding ideas…").foregroundStyle(.secondary)
            }
          } else if let failure = ideas.failure {
            Label(failure, icon: "exclamationmark.triangle").foregroundStyle(.red)
          }
          ForEach(store.goalIdeas.prefix(6)) { idea in
            LabeledContent {
              HStack {
                Button("Use") {
                  draft.fill(idea)
                  goal = idea.source != .spend
                  focused = true
                }
                Button(store.asking.contains(idea.launchKey) ? "Starting…" : "Start") {
                  store.start(idea)
                  dismiss()
                }
                .disabled(store.asking.contains(idea.launchKey))
              }
            } label: {
              Text(idea.title)
              Text(idea.why).lineLimit(2)
            }
            .help(idea.summary ?? idea.task)
            .contextMenu {
              Button("Hide", systemImage: "eye.slash") { ideas.dismiss(idea) }
            }
          }
        } header: {
          HStack {
            Text("Suggestions")
            Spacer()
            Button("New Ideas") { Task { await ideas.ask(store: store) } }
              .controlSize(.small)
              .disabled(ideas.busy)
          }
        } footer: {
          if !ideas.dismissed.isEmpty {
            Button("Show \(ideas.dismissed.count) Hidden") { ideas.restore() }.buttonStyle(.link)
          }
        }
      }
      .formStyle(.grouped)
    }
    .frame(width: 560, height: 640)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel") { dismiss() }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("Start") { start() }
          .keyboardShortcut(.return, modifiers: .command)
          .disabled(!valid)
      }
    }
    .onAppear { focused = true }
  }

  private func start() {
    let task = trimmed
    if goal {
      if let idea = store.goalIdeas.first(where: { $0.launchKey == draft.key }) {
        store.start(idea, task: task, done: draft.done, turns: draft.turns)
      } else {
        store.setGoal(task, done: draft.done, turns: draft.turns)
      }
    } else {
      store.ask(task, loop: draft.loop)
    }
    draft.clear()
    dismiss()
  }
}
