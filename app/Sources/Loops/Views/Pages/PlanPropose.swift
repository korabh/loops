import SwiftUI

struct ProposeForm: View {
  @Environment(Store.self) private var store
  @Environment(\.openURL) private var openURL
  @State private var idea = ""
  @State private var replacing: FeatureIdea?
  @State private var restarting = false

  private var planner: Planner { store.planner }

  var body: some View {
    Form {
      if let p = planner.proposal {
        proposal(p)
      } else {
        Section {
          TextField("Feature", text: $idea, prompt: Text("Describe the feature in a sentence or two"), axis: .vertical)
            .lineLimit(2...5)
            .labelsHidden()
          HStack {
            Spacer()
            Button("Start") {
              planner.start(idea, store: store)
              idea = ""
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(idea.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
        } header: {
          Text("Propose a Feature")
        } footer: {
          Text("Claude asks a few rounds of questions, each with a suggested answer, then publishes a spec as an issue.")
        }
      }
      Section {
        if planner.suggesting {
          HStack {
            ProgressView().controlSize(.small)
            Text("Suggesting features…").foregroundStyle(.secondary)
          }
        } else if let failure = planner.ideasFailure {
          Label(failure, icon: "exclamationmark.triangle").foregroundStyle(.red)
        }
        ForEach(planner.ideas) { idea in
          LabeledContent {
            Button("Explore") {
              if planner.proposal == nil { planner.explore(idea, store: store) } else { replacing = idea }
            }
            .disabled(planner.busy != nil)
          } label: {
            Text(idea.title)
            Text(idea.pitch)
          }
          .help(idea.why)
        }
      } header: {
        HStack {
          Text("Ideas from the Repo")
          Spacer()
          Button(planner.ideas.isEmpty ? "Suggest" : "Suggest Others") { planner.suggest(store: store) }
            .controlSize(.small)
            .disabled(planner.suggesting)
            .help("Claude reads the repo and lists features worth proposing")
        }
      } footer: {
        if let at = planner.ideasAt, !planner.suggesting {
          Text("\(Clock.ago(at, now: store.now))\(planner.ideasUsage.map { " · \($0.label)" } ?? "")")
        }
      }
    }
    .formStyle(.grouped)
    .confirmationDialog(
      "Explore this idea instead?", isPresented: Binding(get: { replacing != nil }, set: { if !$0 { replacing = nil } }),
      presenting: replacing
    ) { idea in
      Button("Start Over", role: .destructive) {
        planner.reset()
        planner.explore(idea, store: store)
      }
    } message: { _ in
      Text("The proposal in progress is discarded.")
    }
    .confirmationDialog("Start over?", isPresented: $restarting) {
      Button("Start Over", role: .destructive) { planner.reset() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("The proposal in progress is discarded.")
    }
  }

  @ViewBuilder private func proposal(_ p: Proposal) -> some View {
    let round = p.current
    Section {
      if let n = p.target { LabeledContent("Rewrites", value: "#\(n) when published") }
      LabeledContent("Round", value: "\(max(1, p.rounds.count)) · \(p.tokens.map { Usage(tokens: $0, cost: p.cost).label } ?? p.cost.usd)")
      if let settled = round?.settled, !settled.isEmpty {
        Text(Briefs.attributed(settled)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      if let busy = planner.busy {
        HStack {
          ProgressView().controlSize(.small)
          Text("\(busy)…")
          if let since = planner.since { Text(since, style: .timer).monospacedDigit().foregroundStyle(.tertiary) }
        }
      }
      if let w = p.waiting, planner.busy == nil {
        LabeledContent {
          HStack {
            Button("Cancel") { planner.stopWaiting() }
            Button("Send Now") { planner.sendNow(store: store) }
          }
        } label: {
          Text("Waiting for the \(UsageLimit(text: w.limit, at: nil, resets: nil).kind) to reset")
          Text("It carries on by itself at \(Clock.day(w.until, now: store.now)), with what you sent.")
        }
      }
      if let failure = planner.failure {
        LabeledContent {
          if p.rounds.isEmpty {
            Button("Try Again") {
              let idea = p.idea
              planner.reset()
              planner.start(idea, store: store)
            }
          }
        } label: {
          Label(failure, icon: "exclamationmark.triangle").foregroundStyle(.red)
        }
      }
    } header: {
      HStack {
        Text(p.idea).lineLimit(2)
        Spacer()
        Button("Start Over…", role: .destructive) { restarting = true }.controlSize(.small)
      }
    }
    if let chart = p.rounds.last(where: { !($0.chart ?? "").isEmpty })?.chart {
      Section("Statechart") {
        StatechartView(source: Mermaid.source(chart), maxHeight: 360)
      }
    }
    if planner.busy == nil {
      if let issue = p.issue {
        Section {
          LabeledContent {
            HStack {
              Button("Propose Another") { planner.reset() }
              if let url = URL(string: issue) { Button("Open Issue") { openURL(url) }.buttonStyle(.borderedProminent) }
            }
          } label: {
            Text("Published\(Briefs.numbers(issue).last.map { " as #\($0)" } ?? "")")
            Text("Issue builder takes it at \(Clock.time(store.nextTick))")
          }
        }
      } else if let round, round.done {
        Section {
          LabeledContent {
            HStack {
              Button("Ask More") { planner.more(store: store) }
              Button("Publish Spec") { planner.publish(store: store) }.buttonStyle(.borderedProminent)
            }
          } label: {
            Text("Every question is settled")
            Text("Publishing writes the spec as an issue labelled ready-for-agent")
          }
        }
      } else if let round {
        ForEach(round.questions) { QuestionSection(question: $0) }
        if p.waiting == nil {
          Section {
            HStack {
              Spacer()
              Button("Send Answers") { planner.send(store: store) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
            }
          } footer: {
            Text("Every answer starts as Claude's suggestion.")
          }
        }
      }
    }
  }
}

private struct QuestionSection: View {
  @Environment(Store.self) private var store
  let question: Round.Question

  private var planner: Planner { store.planner }

  var body: some View {
    let answer = planner.answer(question.id)
    Section {
      Text(Briefs.attributed(question.question)).fixedSize(horizontal: false, vertical: true)
      let options = question.options ?? []
      if !options.isEmpty {
        Picker("Choice", selection: Binding(get: { options.contains(answer.wrappedValue) ? answer.wrappedValue : "" }, set: { answer.wrappedValue = $0 })) {
          ForEach(options, id: \.self) { o in
            Text(o == question.recommended ? "\(o) (suggested)" : o).tag(o)
          }
          Text("Something else").tag("")
        }
        .pickerStyle(.radioGroup)
        .labelsHidden()
      }
      if options.isEmpty || !options.contains(answer.wrappedValue) {
        TextField("Answer", text: answer, prompt: Text("Your answer"), axis: .vertical)
          .lineLimit(1...5)
          .labelsHidden()
      }
    } header: {
      HStack {
        Text("\(question.id.uppercased()) · \(question.title)")
        Spacer()
        if answer.wrappedValue != question.recommended {
          Button("Use Suggestion") { answer.wrappedValue = question.recommended }.controlSize(.small)
        }
      }
    } footer: {
      if let why = question.why { Text(why) }
    }
  }
}
