import SwiftUI

struct PlanPage: View {
  enum Tab: String, CaseIterable, Identifiable {
    case propose, directions, issues

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
  }

  @AppStorage("planTab") private var tab = Tab.propose

  var body: some View {
    Group {
      switch tab {
      case .propose: ProposeForm()
      case .directions: DirectionsForm()
      case .issues: IssuesTable()
      }
    }
    .pageTitle("Plan")
    .viewTabs($tab, Tab.allCases) { $0.title }
    .toolbar {
      ToolbarItem(placement: .principal) {
        Picker("Show", selection: $tab) {
          ForEach(Tab.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
      }
      if tab == .issues {
        ToolbarSpacer(.fixed)
        ToolbarItem { TableViewMenu() }
      }
    }
  }
}
