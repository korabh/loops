import Charts
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
        VStack(alignment: .leading, spacing: 10) {
          HoldersBar(shares: shares).frame(height: 12)
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
      }
      Text(sentence)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.vertical, 6)
  }
}

private struct HoldersBar: View {
  let shares: [Share]

  var body: some View {
    let segments = Attention.segments(shares)
    let total = segments.last?.end ?? 1
    GeometryReader { g in
      let gap = total * 2 / max(Double(g.size.width), 1)
      Chart(segments, id: \.holder) { s in
        BarMark(
          xStart: .value("From", s.start == 0 ? 0 : s.start + gap / 2), xEnd: .value("To", s.end == total ? total : s.end - gap / 2),
          y: .value("Work", "open"), height: .ratio(1)
        )
        .foregroundStyle(s.holder.tint)
      }
      .chartXScale(domain: 0...total)
      .chartXAxis(.hidden)
      .chartYAxis(.hidden)
      .chartLegend(.hidden)
    }
    .clipShape(.capsule)
    .accessibilityElement()
    .accessibilityLabel(shares.map { "\($0.holder.title) \($0.count)" }.joined(separator: ", "))
  }
}

struct WaitTimeline: View {
  let waits: [Wait]
  let now: Date
  let open: (String) -> Void
  @State private var hover: String?

  private let row: CGFloat = 26
  private let axis: CGFloat = 16

  var body: some View {
    let start = waits.map(\.since).min() ?? now
    let span = max(now.timeIntervalSince(start), 3600)
    let from = start.addingTimeInterval(-span * 0.03)
    let to = now.addingTimeInterval(span * 0.015)
    VStack(alignment: .leading, spacing: 10) {
      Text("Waiting since").font(.subheadline).foregroundStyle(.secondary)
      HStack(alignment: .top, spacing: 14) {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(waits) { w in
            Text(w.name)
              .lineLimit(1)
              .frame(height: row, alignment: .leading)
              .contentShape(.rect)
              .onHover { hover = $0 ? w.id : hover == w.id ? nil : hover }
              .onTapGesture { open(w.id) }
              .help(w.title)
          }
        }
        .fixedSize(horizontal: true, vertical: false)
        VStack(spacing: 4) {
          chart(from: from, to: to)
          ticks(from: from, to: to, span: span)
        }
        VStack(alignment: .trailing, spacing: 0) {
          ForEach(waits) { w in
            Text(w.age).monospacedDigit().foregroundStyle(.secondary).frame(height: row)
          }
        }
        .fixedSize()
      }
    }
    .padding(.vertical, 6)
  }

  private func chart(from: Date, to: Date) -> some View {
    Chart {
      ForEach(shown(from: from, to: to), id: \.self) { t in
        RuleMark(x: .value("Day", t)).foregroundStyle(Color.secondary.opacity(0.18)).lineStyle(StrokeStyle(lineWidth: 1))
      }
      ForEach(waits) { w in
        BarMark(xStart: .value("Since", w.since), xEnd: .value("Now", now), y: .value("Item", w.id), height: .fixed(10))
          .foregroundStyle(w.holder.tint)
          .cornerRadius(5)
          .opacity(hover == nil || hover == w.id ? 1 : 0.35)
          .annotation(position: .top, alignment: .leading, spacing: 2, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
            if hover == w.id {
              Text(w.title)
                .font(.callout)
                .lineLimit(2)
                .frame(maxWidth: 320, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.regularMaterial, in: .rect(cornerRadius: 7))
            }
          }
      }
      RuleMark(x: .value("Now", now))
        .foregroundStyle(Color.secondary)
        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
    }
    .chartXScale(domain: from...to)
    .chartYScale(domain: waits.map(\.id))
    .chartXAxis(.hidden)
    .chartYAxis(.hidden)
    .chartOverlay { proxy in
      GeometryReader { g in
        Rectangle().fill(.clear).contentShape(.rect)
          .onContinuousHover { phase in
            switch phase {
            case .active(let p): hover = item(at: p, proxy, g)
            case .ended: hover = nil
            }
          }
          .onTapGesture { p in
            if let id = item(at: p, proxy, g) { open(id) }
          }
      }
    }
    .frame(height: CGFloat(waits.count) * row)
  }

  private func ticks(from: Date, to: Date, span: TimeInterval) -> some View {
    GeometryReader { g in
      let x = { (d: Date) in g.size.width * d.timeIntervalSince(from) / to.timeIntervalSince(from) }
      let hourly = span < 2 * 86400
      ZStack(alignment: .topLeading) {
        ForEach(shown(from: from, to: to), id: \.self) { t in
          Text(t, format: hourly ? .dateTime.hour() : span <= 7 * 86400 ? .dateTime.weekday(.abbreviated) : .dateTime.month(.abbreviated).day())
            .fixedSize()
            .position(x: x(t), y: axis / 2)
        }
        Text("Now").fixedSize().position(x: x(now), y: axis / 2)
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .frame(height: axis)
  }

  private func shown(from: Date, to: Date) -> [Date] {
    let whole = to.timeIntervalSince(from)
    return Attention.ticks(from: from, to: now).filter { t in
      t.timeIntervalSince(from) / whole >= 0.06 && now.timeIntervalSince(t) / whole >= 0.09
    }
  }

  private func item(at p: CGPoint, _ proxy: ChartProxy, _ g: GeometryProxy) -> String? {
    guard let frame = proxy.plotFrame else { return nil }
    let y = p.y - g[frame].origin.y
    guard y >= 0, y <= g[frame].height else { return nil }
    return proxy.value(atY: y, as: String.self)
  }
}
