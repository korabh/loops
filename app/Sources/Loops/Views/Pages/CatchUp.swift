import SwiftUI

struct CatchUpView: View {
  @Environment(Store.self) private var store
  @AppStorage("recallScope") private var scope = RecallScope.away
  @State private var topic = ""

  private var recall: Recall { store.recall }

  var body: some View {
    Form {
      Section {
        Picker("Since", selection: $scope) {
          ForEach(RecallScope.allCases) { Text($0.title).tag($0) }
        }
        TextField("Topic", text: $topic, prompt: Text("Any loop, PR or area"))
          .onSubmit { recall.run(scope, topic: topic, store: store) }
        HStack {
          if let started = recall.started {
            ProgressView().controlSize(.small)
            Text("Reading sessions, briefs and PRs").foregroundStyle(.secondary)
            Text(started, style: .timer).monospacedDigit().foregroundStyle(.tertiary)
          }
          Spacer()
          Button("Catch Me Up") { recall.run(scope, topic: topic, store: store) }
            .buttonStyle(.borderedProminent)
            .disabled(recall.running)
        }
      } header: {
        Text("Catch Up")
      } footer: {
        Text("A read-only Claude Code run on Sonnet, capped at $3.")
      }
      if let failure = recall.failure {
        Section { Label(failure, icon: "exclamationmark.triangle").foregroundStyle(.red) }
      }
      if let b = recall.brief {
        Section {
          ForEach(Array(b.capsule.enumerated()), id: \.offset) { _, line in
            Text(Briefs.attributed(line)).fixedSize(horizontal: false, vertical: true)
          }
        } header: {
          Text("As of \(Clock.day(b.at, now: store.now)) · \(b.window)")
        }
        if !b.threads.isEmpty {
          Section("Threads") {
            ForEach(b.threads) { ThreadLine(thread: $0) }
          }
        }
        if !b.problems.isEmpty {
          Section("Problems") {
            ForEach(b.problems) { p in
              LabeledContent {
                Button("Fix") {
                  store.ask("Look into this recurring problem and fix its root cause, or say why it should stay: \(p.text)", loop: nil)
                }
              } label: {
                Text(Briefs.attributed(p.text))
              }
            }
          }
        }
        Section("Next") {
          LabeledContent {
            if let n = b.next.pr, let url = store.pullURL(n) {
              Button("Open #\(n)") { NSWorkspace.shared.open(url) }
            } else if let prompt = b.next.prompt {
              Button("Start") { store.ask(prompt, loop: nil) }
                .disabled(store.asking.contains(prompt))
            }
          } label: {
            Text(Briefs.attributed(b.next.text))
          }
        }
      }
    }
    .formStyle(.grouped)
  }
}

private struct ThreadLine: View {
  @Environment(Store.self) private var store
  let thread: RecallBrief.Thread

  private var look: (title: String, symbol: String, tint: Color) {
    switch thread.status {
    case "merged": ("Merged", "arrow.triangle.merge", .purple)
    case "open": ("Open", "arrow.triangle.pull", .green)
    case "inflight": ("In flight", "circle.dotted", .orange)
    case "verified": ("Verified", "checkmark.circle", .green)
    case "reverted": ("Reverted", "arrow.uturn.backward", .red)
    default: ("Planned", "circle", .secondary)
    }
  }

  var body: some View {
    let pull = thread.pr.flatMap { store.pulls[$0] }
    LabeledContent {
      if thread.status == "open", let pull, pull.open, store.mergeState(pull).mergeable {
        MergeButton(pr: pull)
      } else if thread.status == "reverted", let n = thread.pr {
        Button("Ask Why") {
          store.ask("Use the why skill: why was #\(n) reverted, and what would make the next attempt hold? It was: \(thread.title)", loop: nil)
        }
      } else if thread.status == "planned" {
        Button("Start") { store.ask(thread.title, loop: nil, done: Goal.pullRequest) }
          .disabled(store.asking.contains(thread.title))
      } else if let n = thread.pr, let url = store.pullURL(n) {
        Button("#\(n)") { NSWorkspace.shared.open(url) }.buttonStyle(.link)
      }
    } label: {
      Label {
        Text(Briefs.attributed(thread.title))
        Text(look.title)
      } icon: {
        Image(icon: look.symbol, size: 14).foregroundStyle(look.tint)
      }
    }
  }
}
