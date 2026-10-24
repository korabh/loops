import SwiftUI

enum RowSize: String, CaseIterable, Identifiable {
  case small, medium, large

  var id: String { rawValue }
  var title: String { rawValue.capitalized }

  var font: Font {
    switch self {
    case .small: .callout
    case .medium: .body
    case .large: .title3
    }
  }

  var height: CGFloat {
    switch self {
    case .small: 20
    case .medium: 26
    case .large: 34
    }
  }

  var control: ControlSize {
    switch self {
    case .small: .small
    case .medium: .regular
    case .large: .large
    }
  }

  var bigger: RowSize { self == .small ? .medium : .large }
  var smaller: RowSize { self == .large ? .medium : .small }
}

enum TableLook: String, CaseIterable, Identifiable {
  case plain, striped, bordered

  var id: String { rawValue }

  var title: String {
    switch self {
    case .plain: "Inset"
    case .striped: "Alternating Rows"
    case .bordered: "Bordered"
    }
  }
}

private struct TableAppearance: ViewModifier {
  @AppStorage("rowSize") private var size = RowSize.medium
  @AppStorage("tableLook") private var look = TableLook.striped

  func body(content: Content) -> some View {
    styled(content)
      .font(size.font)
      .controlSize(size.control)
      .environment(\.defaultMinListRowHeight, size.height)
  }

  @ViewBuilder private func styled(_ content: Content) -> some View {
    switch look {
    case .plain: content.tableStyle(.inset(alternatesRowBackgrounds: false))
    case .striped: content.tableStyle(.inset(alternatesRowBackgrounds: true))
    case .bordered: content.tableStyle(.bordered(alternatesRowBackgrounds: true))
    }
  }
}

extension View {
  func tableAppearance() -> some View { modifier(TableAppearance()) }
}

struct TableViewOptions: View {
  @AppStorage("rowSize") private var size = RowSize.medium
  @AppStorage("tableLook") private var look = TableLook.striped

  var body: some View {
    Picker("Row Size", selection: $size) {
      ForEach(RowSize.allCases) { Text($0.title).tag($0) }
    }
    Picker("Table Style", selection: $look) {
      ForEach(TableLook.allCases) { Text($0.title).tag($0) }
    }
  }
}

struct TableViewMenu: View {
  var body: some View {
    Menu {
      TableViewOptions().pickerStyle(.inline)
    } label: {
      Label("View Options", icon: "slider.horizontal.3")
    }
    .menuIndicator(.hidden)
    .help("Row size and table style")
  }
}

struct TableCommands: Commands {
  @AppStorage("rowSize") private var size = RowSize.medium

  var body: some Commands {
    CommandGroup(before: .toolbar) {
      TableViewOptions()
      Button("Bigger Rows") { size = size.bigger }
        .keyboardShortcut("+")
        .disabled(size == .large)
      Button("Smaller Rows") { size = size.smaller }
        .keyboardShortcut("-")
        .disabled(size == .small)
      Divider()
    }
  }
}
