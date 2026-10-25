import SwiftUI

struct ViewTabs {
  let titles: [String]
  let selected: Int?
  let select: (Int) -> Void
}

extension FocusedValues {
  @Entry var viewTabs: ViewTabs?
}

extension View {
  func viewTabs<T: Hashable>(_ selection: Binding<T>, _ all: [T], title: (T) -> String) -> some View {
    focusedSceneValue(
      \.viewTabs,
      ViewTabs(titles: all.map(title), selected: all.firstIndex(of: selection.wrappedValue)) { selection.wrappedValue = all[$0] })
  }
}

struct ViewCommands: Commands {
  @FocusedValue(\.viewTabs) private var tabs

  var body: some Commands {
    CommandGroup(before: .toolbar) {
      if let tabs {
        ForEach(Array(tabs.titles.prefix(4).enumerated()), id: \.offset) { i, title in
          Toggle(title, isOn: Binding(get: { tabs.selected == i }, set: { if $0 { tabs.select(i) } }))
            .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [.command, .option])
        }
        Divider()
      }
    }
  }
}
