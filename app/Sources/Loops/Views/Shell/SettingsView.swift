import SwiftUI

struct SettingsView: View {
  var body: some View {
    TabView {
      Tab {
        GeneralSettings()
      } label: {
        Label("General", icon: "gearshape")
      }
      Tab {
        AccountSettings()
      } label: {
        Label("Accounts", icon: "person.crop.circle")
      }
    }
    .frame(width: 520, height: 420)
  }
}

private struct GeneralSettings: View {
  @Environment(Store.self) private var store

  var body: some View {
    Form {
      Section {
        Picker("Appearance", selection: store.appearanceBinding) {
          ForEach(Appearance.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        Toggle("Notify when any loop finishes", isOn: store.notifyAllBinding)
      }
      Section("Runner") {
        LabeledContent("Status") {
          Label(store.phase.label, icon: store.phase.healthy ? "checkmark.circle" : "exclamationmark.triangle")
            .foregroundStyle(store.phase.tint)
        }
        if let problem = store.runnerProblem {
          Text(problem).foregroundStyle(.secondary)
        }
        LabeledContent("Next tick", value: Clock.time(store.nextTick))
        HStack {
          if let action = store.action {
            ProgressView().controlSize(.small)
            Text(action).foregroundStyle(.secondary)
          }
          Spacer()
          Button("Open in Terminal") { store.attach() }
          if store.phase == .stopped {
            Button("Start Runner") { store.perform("Starting…", ["start"]) }
          } else if store.phase != .unknown {
            Button("Stop Runner") { store.perform("Stopping…", ["stop"]) }
          }
        }
        .disabled(store.action != nil)
      }
    }
    .formStyle(.grouped)
  }
}

private struct AccountSettings: View {
  @Environment(Store.self) private var store
  @State private var removing: RunnerState.Account?

  var body: some View {
    Form {
      if let r = store.runner {
        Section {
          ForEach(r.accounts) { a in
            let current = a.dir == r.account
            let profile = AccountProfile.read(a.dir)
            LabeledContent {
              HStack {
                if let limit = limit(a) { Text(limit).foregroundStyle(.orange) }
                if current {
                  Image(icon: "checkmark", size: 14).foregroundStyle(.tint)
                } else {
                  Button("Remove…") { removing = a }
                  Button("Use") { store.perform("Moving…", ["account", "use", a.dir]) }
                    .disabled(a.email == nil || store.action != nil)
                }
              }
            } label: {
              Text(profile?.name ?? a.name)
              Text([profile?.email, profile?.organization].compactMap { $0 }.joined(separator: " · "))
            }
            .contextMenu {
              Button("Remove from the Runner…", role: .destructive) { removing = a }
                .disabled(current)
            }
          }
        } header: {
          Text("Runner Accounts")
        } footer: {
          Text(
            r.accounts.count > 1
              ? "When one account hits its usage limit, the runner moves to the next."
              : "Add a second account and the runner moves to it when this one hits its usage limit.")
        }
        Section {
          HStack {
            Spacer()
            Button("Add Account…") { store.addAccount() }
          }
        }
      } else {
        Section {
          Text(store.runnerProblem ?? "The runner's accounts are loading.").foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
    .confirmationDialog(
      removing.map { "Remove \($0.name) from the runner?" } ?? "",
      isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
      presenting: removing
    ) { a in
      Button("Remove") { store.perform("Removing…", ["account", "remove", a.dir]) }
      Button("Remove and Sign Out", role: .destructive) { store.perform("Removing…", ["account", "remove", a.dir, "--sign-out"]) }
      Button("Cancel", role: .cancel) {}
    } message: { _ in
      Text("Remove keeps it signed in. Remove and Sign Out does not.")
    }
  }

  private func limit(_ a: RunnerState.Account) -> String? {
    guard let at = a.limitedAt else { return nil }
    let resets = a.limit.flatMap { UsageLimit.resets(in: $0, after: Date(timeIntervalSince1970: at)) }
    return resets.map { "Limit until \(Clock.time($0))" } ?? "At its limit"
  }
}
