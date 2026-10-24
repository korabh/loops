import SwiftUI

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
          .font(.system(size: 40, weight: .semibold, design: .rounded))
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
