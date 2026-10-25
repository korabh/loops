import SwiftUI

struct DirectionsForm: View {
  @Environment(Store.self) private var store
  @State private var dismissing: Direction?
  @State private var reason = ""
  @State private var replacing: Direction?

  private var directions: Directions { store.directions }

  var body: some View {
    Form {
      Section {
        TextField("Destination", text: directions.destinationBinding, prompt: Text(Directions.defaultDestination), axis: .vertical)
          .lineLimit(1...3)
          .labelsHidden()
        LabeledContent("Loops needed you") {
          if let n = directions.needed {
            Text("\(plural(n.last7, "time")) in 7 days, \(n.prior7) the week before").monospacedDigit()
          } else if let problem = directions.uncounted {
            Text("Couldn't count").foregroundStyle(.secondary).help(problem)
          } else {
            ProgressView().controlSize(.small)
          }
        }
      } header: {
        Text("Where Should the Loops Get To?")
      } footer: {
        Text("Claude works back from this destination.")
      }
      Section {
        if directions.busy {
          HStack {
            ProgressView().controlSize(.small)
            Text("Reading the loops' records…").foregroundStyle(.secondary)
            if let since = directions.since { Text(since, style: .timer).monospacedDigit().foregroundStyle(.tertiary) }
          }
        } else if let failure = directions.failure {
          Label(failure, icon: "exclamationmark.triangle").foregroundStyle(.red)
        } else if directions.stale {
          Text("New records since this run. Ask again to include them.").foregroundStyle(.secondary)
        }
        if directions.at != nil, !directions.busy, directions.visible.isEmpty {
          Text(directions.list.isEmpty ? "Nothing recurring" : "Nothing new since you dismissed the last ones").foregroundStyle(.secondary)
        }
      } header: {
        HStack {
          Text("Questions You're Not Asking")
          Spacer()
          Button(directions.at == nil ? "Ask" : "Ask Again") { directions.ask(store: store) }
            .controlSize(.small)
            .disabled(directions.busy)
            .help("Claude reads the loops' notes, lessons, briefs and your answers, checks them against the code, and returns up to three directions, for at most $\(Directions.budget). It never files anything.")
        }
      } footer: {
        if let at = directions.at, !directions.busy {
          Text("\(Clock.ago(at, now: store.now))\(directions.usage.map { " · \($0.label)" } ?? "")")
        }
      }
      if directions.at != nil, !directions.busy {
        ForEach(directions.visible) { d in
          Section {
            Text(d.question).font(.headline).fixedSize(horizontal: false, vertical: true)
            Text(d.gap).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(d.evidence, id: \.self) { e in
              let parts = Reader.groups(#"^(\d+)\s+(.+)$"#, in: e)
              LabeledContent(parts.count == 2 ? parts[1] : e, value: parts.first ?? "")
            }
            VStack(alignment: .leading, spacing: 4) {
              Text("Not yet")
              Text(d.notYet).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
              Spacer()
              Button("Dismiss…") { dismissing = d }
              Button("Explore") {
                if store.planner.proposal == nil { directions.explore(d, store: store) } else { replacing = d }
              }
              .buttonStyle(.borderedProminent)
              .disabled(store.planner.busy != nil)
            }
          } header: {
            Text("\(d.rung.title) · builds \(d.rung.builds)")
          }
        }
      }
    }
    .formStyle(.grouped)
    .task { await directions.watch(store: store) }
    .alert(
      "Why pass on this?", isPresented: Binding(get: { dismissing != nil }, set: { if !$0 { dismissing = nil } }), presenting: dismissing
    ) { d in
      TextField("Reason", text: $reason)
      Button("Dismiss") {
        directions.dismiss(d, reason: reason)
        reason = ""
      }
      .disabled(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      Button("Cancel", role: .cancel) { reason = "" }
    } message: { _ in
      Text("The next run reads your reason, and asks this again only once its evidence grows.")
    }
    .confirmationDialog(
      "Explore this direction instead?", isPresented: Binding(get: { replacing != nil }, set: { if !$0 { replacing = nil } }),
      presenting: replacing
    ) { d in
      Button("Start Over with This Direction", role: .destructive) {
        store.planner.reset()
        directions.explore(d, store: store)
      }
    } message: { _ in
      Text("The proposal in progress and its answers are discarded.")
    }
  }
}
