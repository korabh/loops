import SwiftUI

struct LoopPage: View {
  enum Tab: String, CaseIterable, Identifiable {
    case overview, spend, health

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
  }

  @Environment(Store.self) private var store
  @AppStorage("loopTab") private var tab = Tab.overview
  @State private var asked: String?
  let spec: LoopSpec

  var body: some View {
    Group {
      switch tab {
      case .overview: LoopOverview(spec: spec)
      case .spend: LoopSpend(spec: spec)
      case .health: LoopHealth(spec: spec)
      }
    }
    .safeAreaBar(edge: .bottom, spacing: 0) {
      Composer(prompt: "Ask Claude Code about \(spec.title)", busy: asked.map(store.asking.contains) ?? false) { text in
        let key = "loop-ask:\(spec.name):\(Int(Date().timeIntervalSince1970))"
        asked = key
        store.ask(
          "About the loop \(spec.name) (\(spec.title)), whose skill is .claude/skills/\(spec.name)/SKILL.md: \(text)", loop: spec.name, from: key)
      } status: {
        if let asked, let t = store.task(key: asked) {
          HStack(spacing: 6) {
            Text("Claude Code is on it")
            Button("Open") { store.page = .task(t.stable) }.buttonStyle(.link)
          }
        }
      }
    }
    .focusedSceneValue(\.selected, Selected(loops: [spec.name]))
    .pageTitle(spec.title)
    .viewTabs($tab, Tab.allCases) { $0.title }
    .toolbar {
      ToolbarItem(placement: .principal) {
        Picker("Show", selection: $tab) {
          ForEach(Tab.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
      }
      ToolbarItem {
        Button("Run Now", icon: "play") { store.runNow(spec.name) }
          .disabled(store.running[spec.name] != nil || store.isStarting(spec.name))
          .help("Start \(spec.title) now instead of waiting for its next tick")
      }
      ToolbarItem {
        Menu {
          LoopMenu(spec: spec, run: false)
        } label: {
          Label("More", icon: "ellipsis")
        }
        .menuIndicator(.hidden)
        .help("Enable, edit or remove \(spec.title)")
      }
    }
  }
}
