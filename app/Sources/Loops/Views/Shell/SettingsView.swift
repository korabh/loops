import SwiftUI

struct SettingsView: View {
  var body: some View {
    TabView {
      Tab {
        GeneralSettings().frame(width: 520, height: 160)
      } label: {
        Label("General", icon: "gearshape", size: 20)
      }
      Tab {
        ProjectSettings().frame(width: 600, height: 520)
      } label: {
        Label("Projects", icon: "folder", size: 20)
      }
      Tab {
        AccountSettings().frame(width: 600, height: 460)
      } label: {
        Label("Accounts", icon: "person.crop.circle", size: 20)
      }
    }
  }
}

private struct GeneralSettings: View {
  @Environment(Workspace.self) private var workspace

  var body: some View {
    Form {
      Section {
        Picker(
          "Appearance",
          selection: Binding(get: { workspace.focus?.appearance ?? .system }, set: { workspace.setAppearance($0) })
        ) {
          ForEach(Appearance.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        Toggle(
          "Notify when any loop finishes",
          isOn: Binding(get: { workspace.focus?.notifyAll ?? false }, set: { workspace.setNotifyAll($0) }))
      }
    }
    .formStyle(.grouped)
  }
}

private struct Problems: View {
  @Environment(Workspace.self) private var workspace

  var body: some View {
    let notices = workspace.ordered.compactMap { s in s.notice.map { (s, $0) } }
    if workspace.problem != nil || !notices.isEmpty {
      Section {
        if let problem = workspace.problem {
          Text(problem).foregroundStyle(.orange)
        }
        ForEach(notices, id: \.0.id) { s, notice in
          LabeledContent {
            Button("Dismiss") { s.notice = nil }
          } label: {
            Text(s.name)
            Text(notice)
          }
        }
      }
    }
  }
}

private struct ProjectSettings: View {
  @Environment(Workspace.self) private var workspace
  @State private var choosing = false
  @State private var removing: Store?

  var body: some View {
    Form {
      Problems()
      ForEach(workspace.ordered, id: \.id) { s in
        ProjectSection(remove: { removing = s }).environment(s)
      }
      Section {
        HStack {
          if workspace.adding {
            ProgressView().controlSize(.small)
            Text("Adding…").foregroundStyle(.secondary)
          }
          Spacer()
          Button("Add Project…") { choosing = true }
            .disabled(workspace.adding)
        }
      } footer: {
        Text("A project is a git repository with its loops in .claude/loops.json.")
      }
    }
    .formStyle(.grouped)
    .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
      if case .success(let url) = result { workspace.add(url) }
    }
    .confirmationDialog(
      removing.map { "Remove \($0.name) from Loops?" } ?? "",
      isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
      presenting: removing
    ) { s in
      Button("Remove", role: .destructive) { workspace.remove(s) }
      Button("Cancel", role: .cancel) {}
    } message: { _ in
      Text("Stop its runner first. The repository and its loops stay as they are.")
    }
  }
}

private struct ProjectSection: View {
  @Environment(Store.self) private var store
  let remove: () -> Void

  var body: some View {
    let r = store.runner
    let own = r?.accounts.filter { $0.own == true } ?? []
    Section {
      LabeledContent("Folder") {
        Text(store.paths.repo.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
      }
      LabeledContent("Runner") {
        HStack {
          if let action = store.action {
            ProgressView().controlSize(.small)
            Text(action).foregroundStyle(.secondary)
          } else {
            Label(store.phase.label, icon: store.phase.healthy ? "checkmark.circle" : "exclamationmark.triangle")
              .foregroundStyle(store.phase.tint)
          }
          Button("Open in Terminal") { store.attach() }
          if store.phase == .stopped {
            Button("Start") { store.perform("Starting…", ["start"]) }
          } else if store.phase != .unknown {
            Button("Stop") { store.perform("Stopping…", ["stop"]) }
          }
        }
        .disabled(store.action != nil)
      }
      if let r {
        LabeledContent("Account") {
          Menu(r.accounts.first { $0.dir == r.account }?.email ?? r.account) {
            ForEach(r.accounts) { a in
              Button(a.email ?? a.dir) { store.perform("Moving…", ["account", "use", a.dir]) }
                .disabled(a.dir == r.account || a.email == nil)
            }
          }
          .fixedSize()
        }
        Toggle(
          "Use shared accounts after its own",
          isOn: Binding(
            get: { r.useShared ?? true },
            set: { store.perform($0 ? "Sharing…" : "Keeping to its own…", ["account", "shared", $0 ? "on" : "off"]) })
        )
        .disabled(store.action != nil)
        ForEach(own) { a in
          LabeledContent {
            Button("Share") { store.perform("Sharing…", ["account", "share", a.dir]) }
          } label: {
            Text(a.email ?? a.dir)
            Text("Its own account")
          }
        }
      } else if let problem = store.runnerProblem {
        Text(problem).foregroundStyle(.secondary)
      }
    } header: {
      Text(store.name)
    } footer: {
      HStack {
        Button("Add Own Account…") { store.addAccount(own: true) }
        Spacer()
        Button("Remove Project…", role: .destructive, action: remove)
      }
      .buttonStyle(.link)
    }
  }
}

private struct AccountRow: Identifiable {
  let dir: String
  let owner: Store?
  let account: RunnerState.Account?

  var id: String { dir }
}

private struct AccountSettings: View {
  @Environment(Workspace.self) private var workspace
  @State private var removing: AccountRow?
  @State private var registered: [String] = []
  @State private var profiles: [String: AccountProfile] = [:]

  private var known: [(Store, RunnerState.Account)] {
    workspace.ordered.flatMap { s in (s.runner?.accounts ?? []).map { (s, $0) } }
  }

  private var rows: [AccountRow] {
    let known = known
    let dirs = Array(Set(known.map(\.1.dir) + registered)).sorted()
    return dirs.map { dir in
      let owner = known.first { $0.1.dir == dir && $0.1.own == true }?.0
      let account = known.first { $0.1.dir == dir && $0.1.limitedAt != nil }?.1 ?? known.first { $0.1.dir == dir }?.1
      return AccountRow(dir: dir, owner: owner, account: account)
    }
  }

  var body: some View {
    let stores = workspace.ordered
    let dirs = known.map(\.1.dir)
    Form {
      Problems()
      Section {
        ForEach(rows) { row in
          let profile = profiles[row.dir]
          LabeledContent {
            HStack {
              if let limit = limit(row.account) { Text(limit).foregroundStyle(.orange) }
              Text(row.owner.map { "\($0.name) only" } ?? "Shared").foregroundStyle(.secondary)
              if let owner = row.owner {
                Button("Share") { owner.perform("Sharing…", ["account", "share", row.dir]) }
              } else if !stores.isEmpty {
                Menu("Give To") {
                  ForEach(stores, id: \.id) { s in
                    Button(s.name) { s.perform("Moving…", ["account", "own", row.dir]) }
                  }
                }
                .fixedSize()
              }
            }
          } label: {
            Text(profile?.name ?? row.account?.name ?? row.dir)
            Text([profile?.email, profile?.organization, row.dir].compactMap { $0 }.joined(separator: " · "))
          }
          .contextMenu {
            Button("Remove…", role: .destructive) { removing = row }
          }
        }
      } header: {
        Text("Accounts on This Mac")
      } footer: {
        Text(
          "A shared account serves every project that uses shared accounts. A project's own account serves only that project, and its runner tries it first when an account hits its usage limit."
        )
      }
      Section {
        HStack {
          Spacer()
          Button("Add Shared Account…") { workspace.focus?.addAccount() }
            .disabled(workspace.focus == nil)
        }
      }
    }
    .formStyle(.grouped)
    .task(id: dirs + stores.map { $0.action ?? "" }) {
      let (accounts, found) = await Task.detached {
        let accounts = Registry.read()?.accounts ?? []
        let found = Set(dirs + accounts).reduce(into: [String: AccountProfile]()) { out, dir in out[dir] = AccountProfile.read(dir) }
        return (accounts, found)
      }.value
      registered = accounts
      profiles = found
    }
    .confirmationDialog(
      removing.map { "Remove \(profiles[$0.dir]?.email ?? $0.dir)?" } ?? "",
      isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
      presenting: removing
    ) { row in
      let s = row.owner ?? workspace.focus
      Button("Remove") { s?.perform("Removing…", ["account", "remove", row.dir]) }
      Button("Remove and Sign Out", role: .destructive) { s?.perform("Removing…", ["account", "remove", row.dir, "--sign-out"]) }
      Button("Cancel", role: .cancel) {}
    } message: { _ in
      Text("Remove keeps the folder signed in. Remove and Sign Out does not.")
    }
  }

  private func limit(_ a: RunnerState.Account?) -> String? {
    guard let a, let at = a.limitedAt else { return nil }
    let resets = a.limit.flatMap { UsageLimit.resets(in: $0, after: Date(timeIntervalSince1970: at)) }
    return resets.map { "Limit until \(Clock.time($0))" } ?? "At its limit"
  }
}
