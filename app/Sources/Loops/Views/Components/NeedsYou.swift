import SwiftUI

struct NeedsYouSection<Rows: View, Header: View, Footer: View>: View {
  @Environment(Store.self) private var store
  let open: (Share) -> Void
  @ViewBuilder var rows: Rows
  @ViewBuilder var header: Header
  @ViewBuilder var footer: (Int) -> Footer

  var body: some View {
    let inbox = store.inbox
    let pulls = Array(store.pulls.values)
    let shares = Attention.shares(inbox: inbox, pulls: pulls)
    let waits = store.waits(inbox)
    let loops = shares.first { $0.holder == .loops }?.count ?? 0
    let loaded = store.githubLoaded || !store.pulls.isEmpty
    Section {
      NeedsYouSummary(
        waiting: inbox.count, merged: Attention.merged(pulls, now: store.now), shares: loaded ? shares.filter { $0.count > 0 } : [],
        sentence: Attention.sentence(counts: Attention.counts(inbox), loops: loops, oldest: waits.first.map { ($0.name, $0.seconds) }),
        open: open
      )
      .redacted(reason: loaded ? [] : .placeholder)
      rows
    } header: {
      header
    } footer: {
      footer(inbox.count)
    }
  }
}

struct NeedsYouSummary: View {
  let waiting: Int
  let merged: Int
  let shares: [Share]
  let sentence: String
  let open: (Share) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text("\(waiting)")
          .font(.system(.largeTitle, design: .rounded, weight: .semibold))
          .monospacedDigit()
          .contentTransition(.numericText(value: Double(waiting)))
        Text("waiting on you")
          .font(.title3)
          .foregroundStyle(.secondary)
        Spacer(minLength: 12)
        Text("\(merged) merged this week")
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .contentTransition(.numericText(value: Double(merged)))
      }
      .animation(.default, value: waiting)
      .animation(.default, value: merged)
      if !shares.isEmpty {
        HStack(spacing: 20) {
          ForEach(shares) { s in
            Button {
              open(s)
            } label: {
              HStack(spacing: 6) {
                Circle().fill(s.holder.tint).frame(width: 8, height: 8)
                Text(s.holder.title)
                Text("\(s.count)").monospacedDigit().foregroundStyle(.secondary)
                  .contentTransition(.numericText(value: Double(s.count)))
              }
              .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(s.holder.hint)
          }
        }
        .animation(.default, value: shares)
      }
      Text(sentence)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.vertical, 6)
  }
}

struct RunningLoops: View {
  @Environment(Store.self) private var store
  let open: (String) -> Void

  var body: some View {
    ForEach(store.running.sorted { $0.value < $1.value }, id: \.key) { name, started in
      RunningLoopRow(name: name, started: started) { open(name) }
    }
  }
}

struct RunningLoopRow: View {
  @Environment(Store.self) private var store
  let name: String
  let started: Date
  let open: () -> Void

  var body: some View {
    Button(action: open) {
      LabeledContent {
        Text(Clock.short(store.now.timeIntervalSince(started))).monospacedDigit()
      } label: {
        Label {
          Text(store.title(name))
          if let step = store.liveStep(name) { Text(step).lineLimit(1) }
        } icon: {
          WorkingIcon(symbol: Symbols.loop(name), size: 16)
        }
      }
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
  }
}
