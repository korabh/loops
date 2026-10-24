import SwiftUI

struct AnswerForm: View {
  @Environment(Store.self) private var store
  let task: BgTask
  @State private var picked: String?
  @State private var text = ""

  private static let own = "\u{0}own"

  var body: some View {
    let input = store.pendingInput(task)
    let key = "\(task.id):\(input?.title.prefix(80) ?? "")"
    let choices = (input?.options.isEmpty == false ? input?.choices : Suggester.shared.replies[key]) ?? []
    let suggested = input?.recommended.map { $0.replacingOccurrences(of: " (Recommended)", with: "", options: .caseInsensitive) } ?? choices.first?.label
    let current = picked ?? suggested ?? Self.own
    let reply = current == Self.own ? text : (choices.first { $0.label == current }?.reply ?? "")
    let sending = store.asking.contains("reply:\(task.id)")
    let title = input?.title ?? "It needs your answer to continue"
    VStack(alignment: .leading, spacing: 10) {
      Text(Briefs.attributed(title)).font(.headline).fixedSize(horizontal: false, vertical: true)
      if let detail = input?.detail {
        Text(Briefs.attributed(detail)).foregroundStyle(.secondary).lineLimit(4).help(detail)
      }
      if choices.isEmpty {
        HStack(spacing: 6) {
          ProgressView().controlSize(.small)
          Text("Suggesting answers…").foregroundStyle(.secondary)
        }
      }
      Picker("Answer", selection: Binding(get: { current }, set: { picked = $0 })) {
        ForEach(choices) { c in
          VStack(alignment: .leading, spacing: 2) {
            Text(c.label == suggested ? "\(c.label) (suggested)" : c.label)
            if let note = c.note, !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary) }
          }
          .tag(c.label)
        }
        Text("Something else").tag(Self.own)
      }
      .pickerStyle(.radioGroup)
      .labelsHidden()
      if current == Self.own {
        TextField("Your answer", text: $text, prompt: Text("Your answer"), axis: .vertical)
          .lineLimit(2...5)
          .labelsHidden()
      }
      HStack {
        Spacer()
        if sending {
          ProgressView().controlSize(.small)
          Text("Sent").foregroundStyle(.secondary)
        } else {
          Button("Send") { store.reply(task, reply) }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
    }
    .task(id: key) {
      if input == nil || input?.options.isEmpty == true, Suggester.shared.screens[task.id] == nil {
        await Suggester.shared.screen(task, store: store)
      }
      if let input = store.pendingInput(task) { await Suggester.shared.load(key, input, store: store) }
    }
  }
}

struct ReplyForm: View {
  @Environment(Store.self) private var store
  let item: Item
  @State private var answer = ""

  var body: some View {
    let started = store.started[item.id] != nil
    VStack(alignment: .trailing, spacing: 8) {
      TextField("Reply", text: $answer, prompt: Text("Your answer for Claude Code"), axis: .vertical)
        .lineLimit(2...6)
        .labelsHidden()
      HStack {
        if store.asking.contains(item.id) {
          ProgressView().controlSize(.small)
          Text("Starting…").foregroundStyle(.secondary)
        } else if started {
          Text("Claude Code is on it").foregroundStyle(.secondary)
        }
        Spacer()
        Button("Send") { send() }
          .keyboardShortcut(.return, modifiers: .command)
          .disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
  }

  private func send() {
    let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    store.reply(item, text)
    answer = ""
  }
}
