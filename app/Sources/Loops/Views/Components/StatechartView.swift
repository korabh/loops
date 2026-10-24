import QuickLook
import SwiftUI

struct StatechartView: View {
  @Environment(Store.self) private var store
  @Environment(\.colorScheme) private var scheme
  let source: String
  var maxHeight: CGFloat?
  @State private var preview: URL?

  private var charts: Statecharts { .shared }

  var body: some View {
    let theme = scheme == .dark ? "dark" : "light"
    Group {
      switch charts.drawing(source, theme: theme) {
      case .drawn(let url)?:
        if let image = charts.image(url) {
          Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: image.size.width, maxHeight: maxHeight.map { min($0, image.size.height) })
            .clipShape(.rect(cornerRadius: 6))
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
            .onTapGesture { preview = url }
            .help("Click to open full size")
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Statechart")
        }
      case .failed(let why)?:
        Label(why, icon: "exclamationmark.triangle").foregroundStyle(.red).lineLimit(1).help(why)
      default:
        HStack {
          ProgressView().controlSize(.small)
          Text("Drawing the statechart…").foregroundStyle(.secondary)
        }
      }
    }
    .task(id: "\(theme)\n\(source)") { await charts.draw(source, theme: theme, paths: store.paths) }
    .quickLookPreview($preview)
  }
}

struct PullStatecharts: View {
  let pr: Int

  var body: some View {
    let charts = Statecharts.shared.bodies[pr] ?? []
    if !charts.isEmpty {
      Section(charts.count == 1 ? "Statechart" : "Statecharts") {
        ForEach(Array(charts.enumerated()), id: \.offset) { _, source in
          StatechartView(source: source)
        }
      }
    }
  }
}
