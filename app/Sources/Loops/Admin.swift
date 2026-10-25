import SwiftUI

enum LoopEdit: Identifiable {
  case add
  case edit(LoopSpec)
  case remove(LoopSpec)

  var id: String {
    switch self {
    case .add: "add"
    case .edit(let l): "edit-\(l.name)"
    case .remove(let l): "remove-\(l.name)"
    }
  }
}

struct LoopDraft: Equatable {
  var title = ""
  var every = 24
  var windowed = false
  var from = 8
  var until = 20
  var alone = false
  var model = "opus"
  var worktree = true
  var description = ""
  var ships = ""
  var steps = ""
  var group = ""

  var name: String {
    let slug = title.lowercased()
      .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
      .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return "loop-\(slug)"
  }
}

struct LoopChange: Identifiable {
  let loop: String
  let label: String
  let payload: [String: Any]

  var id: String { "\(loop):\(label)" }
  var model: String? { payload["model"] as? String }

  static let cadences = [1, 2, 6, 24, 168]
  static let windows: [[Int]] = [[8, 20], [9, 18], [0, 6], [20, 24]]

  static func every(_ spec: LoopSpec, _ v: Int) -> LoopChange {
    LoopChange(loop: spec.name, label: "run \(LoopSpec.cadence(v).lowercased())", payload: ["every": v])
  }

  static func hours(_ spec: LoopSpec, _ v: [Int]?) -> LoopChange {
    LoopChange(
      loop: spec.name, label: v.map { String(format: "run only between %02d:00 and %02d:00", $0[0], $0[1]) } ?? "run at any time",
      payload: ["hours": v.map { $0 as Any } ?? NSNull()])
  }

  static func model(_ spec: LoopSpec, _ m: String) -> LoopChange {
    LoopChange(loop: spec.name, label: "use \(m.capitalized)", payload: ["model": m])
  }
}

struct ChangeStatus {
  let change: LoopChange
  var opened: URL?
  var failure: String?

  var working: Bool { opened == nil && failure == nil }
}

extension Store {
  func apply(_ change: LoopChange) async {
    changes[change.loop] = ChangeStatus(change: change)
    var payload = change.payload
    payload["action"] = "edit"
    payload["name"] = change.loop
    let result = await admin(payload)
    if result.ok, let line = result.out.split(separator: "\n").last, let url = URL(string: String(line)), url.scheme == "https" {
      changes[change.loop]?.opened = url
      if let m = change.model { recordModelPR(change.loop, model: m, url: url) }
      await refreshGitHub()
    } else {
      changes[change.loop]?.failure = result.err.split(separator: "\n").last.map(String.init) ?? "loop-admin failed."
    }
  }

  var adminScript: URL? { paths.tool("loop-admin") }

  func draft(for l: LoopSpec) -> LoopDraft {
    var d = LoopDraft()
    d.title = l.title
    d.every = l.every
    if let from = l.from, let until = l.until {
      d.windowed = true
      d.from = from
      d.until = until
    }
    d.alone = l.alone
    d.group = l.group ?? ""
    d.description = descriptions[l.name] ?? ""
    let agent = Reader.text(paths.runner.appending(path: ".claude/agents/\(l.name).md")) ?? ""
    d.model = Reader.groups(#"(?m)^model:\s*(\w+)"#, in: agent).first ?? "opus"
    d.worktree = agent.contains("isolation: worktree")
    return d
  }

  func admin(_ payload: [String: Any]) async -> (ok: Bool, out: String, err: String) {
    guard let script = adminScript, let data = try? JSONSerialization.data(withJSONObject: payload) else {
      return (false, "", "This build of Loops has no loop-admin.")
    }
    return await Shell.pipe(["bash", script.path], in: paths.repo, input: data)
  }
}

extension Shell {
  static func pipe(_ command: [String], in dir: URL, input: Data) async -> (ok: Bool, out: String, err: String) {
    await withCheckedContinuation { cont in
      DispatchQueue.global(qos: .userInitiated).async {
        let fm = FileManager.default
        let out = fm.temporaryDirectory.appending(path: "loops-\(UUID().uuidString).out")
        let err = fm.temporaryDirectory.appending(path: "loops-\(UUID().uuidString).err")
        fm.createFile(atPath: out.path, contents: nil)
        fm.createFile(atPath: err.path, contents: nil)
        guard let o = try? FileHandle(forWritingTo: out), let e = try? FileHandle(forWritingTo: err) else {
          cont.resume(returning: (false, "", "Could not open a log file."))
          return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = command
        p.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        let home = fm.homeDirectoryForCurrentUser.path
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        let stdin = Pipe()
        p.standardInput = stdin
        p.standardOutput = o
        p.standardError = e
        do {
          try p.run()
        } catch {
          cont.resume(returning: (false, "", error.localizedDescription))
          return
        }
        stdin.fileHandleForWriting.write(input)
        try? stdin.fileHandleForWriting.close()
        p.waitUntilExit()
        try? o.close()
        try? e.close()
        let so = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
        let se = (try? String(contentsOf: err, encoding: .utf8)) ?? ""
        try? fm.removeItem(at: out)
        try? fm.removeItem(at: err)
        cont.resume(returning: (p.terminationStatus == 0, so, se))
      }
    }
  }
}

extension LoopSpec {
  static func cadence(_ every: Int) -> String {
    switch every {
    case 1: "Every hour"
    case 24: "Daily"
    case 168: "Weekly"
    default: every % 24 == 0 ? "Every \(every / 24) days" : "Every \(every) hours"
    }
  }
}

struct LoopEditor: View {
  @Environment(Store.self) private var store
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openURL) private var openURL
  let mode: LoopEdit
  let original: LoopDraft
  @State private var draft: LoopDraft
  @State private var preview: String?
  @State private var busy = false
  @State private var error: String?
  @State private var opened: URL?
  @State private var template = ""
  @State private var newGroup = false

  private var groupChoices: [String] {
    let known = store.loopGroups.map(\.name).filter { $0 != "Other" }
    return Groups.order + known.filter { !Groups.order.contains($0) }
  }

  init(mode: LoopEdit, original: LoopDraft) {
    self.mode = mode
    self.original = original
    _draft = State(initialValue: original)
  }

  private var title: String {
    switch mode {
    case .add: "New Loop"
    case .edit(let l): "Edit \(l.title)"
    case .remove(let l): "Remove \(l.title)"
    }
  }

  private var name: String {
    switch mode {
    case .add: draft.name
    case .edit(let l), .remove(let l): l.name
    }
  }

  private var titleOK: Bool {
    draft.title.range(of: #"^[A-Za-z0-9][A-Za-z0-9 &+./-]*$"#, options: .regularExpression) != nil
  }

  private var valid: Bool {
    switch mode {
    case .add:
      titleOK && draft.name.count > 5 && !draft.description.isEmpty && !taken
    case .edit: draft != original && titleOK
    case .remove: true
    }
  }

  private var payload: [String: Any] {
    switch mode {
    case .remove:
      return ["action": "remove", "name": name]
    case .add:
      var p: [String: Any] = [
        "action": "add", "name": name, "title": draft.title, "every": draft.every, "alone": draft.alone,
        "model": draft.model, "worktree": draft.worktree, "description": draft.description, "ships": draft.ships,
        "steps": draft.steps,
      ]
      if draft.windowed { p["hours"] = [draft.from, draft.until] }
      if !draft.group.isEmpty { p["group"] = draft.group }
      return p
    case .edit:
      var p: [String: Any] = ["action": "edit", "name": name]
      if draft.title != original.title { p["title"] = draft.title }
      if draft.every != original.every { p["every"] = draft.every }
      if draft.windowed != original.windowed || draft.from != original.from || draft.until != original.until {
        p["hours"] = draft.windowed ? [draft.from, draft.until] : NSNull()
      }
      if draft.alone != original.alone { p["alone"] = draft.alone }
      if draft.group != original.group { p["group"] = draft.group.isEmpty ? NSNull() : draft.group }
      if draft.model != original.model { p["model"] = draft.model }
      if draft.worktree != original.worktree { p["worktree"] = draft.worktree }
      if draft.description != original.description { p["description"] = draft.description }
      if !draft.ships.isEmpty { p["ships"] = draft.ships }
      return p
    }
  }

  private var subtitle: String {
    switch mode {
    case .add: "Runs once its pull request merges."
    case .edit: "Applies once its pull request merges."
    case .remove: "Stops once its pull request merges."
    }
  }

  private var taken: Bool {
    if case .add = mode { return store.specs.contains { $0.name == draft.name } }
    return false
  }

  private func steps(of loop: String) -> String {
    let skill = Reader.text(store.paths.skill(loop)) ?? ""
    guard let start = skill.range(of: "## Steps") else { return "" }
    let rest = skill[start.upperBound...]
    let end = rest.range(of: "\n## ")?.lowerBound ?? rest.endIndex
    return rest[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.headline)
        Text(subtitle).foregroundStyle(.secondary)
      }
      .padding(.horizontal, 20)
      .padding(.top, 16)
      Form {
        if store.adminScript == nil {
          Section {
            Label("The admin script isn't on this Mac yet", icon: "exclamationmark.triangle")
              .help("Waiting on loop-admin, which turns this into a pull request. You can fill this in now.")
          }
        }
        sections
      }
      .formStyle(.grouped)
    }
    .presentationSizing(.form)
    .disabled(busy)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button(opened == nil ? "Cancel" : "Done") { dismiss() }
      }
      ToolbarItem(placement: .automatic) {
        Button("Preview") { Task { await run(dry: true) } }
          .disabled(!valid || store.adminScript == nil || opened != nil)
          .help("Show the changes the pull request makes")
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("Open PR") { Task { await run(dry: false) } }
          .disabled(!valid || store.adminScript == nil || opened != nil)
          .help(mode.isRemove ? "Open a pull request that removes this loop" : "Open a pull request with these changes")
      }
    }
    .overlay {
      if busy { ProgressView().controlSize(.large) }
    }
  }

  @ViewBuilder private var sections: some View {
    if case .remove(let l) = mode {
      Section {
        LabeledContent("Loop", value: l.title)
        LabeledContent("Runs", value: l.cadence)
        LabeledContent("ID", value: l.name)
      } footer: {
        Text("Deletes its skill and agent. Past briefs and results stay.")
      }
    } else {
      if case .add = mode {
        Section {
          Picker("Start from", selection: $template) {
            Text("Blank").tag("")
            Divider()
            ForEach(store.specs) { Text($0.title).tag($0.name) }
          }
          .help("Copies the schedule, model and steps of a loop you already have")
        }
        .onChange(of: template) { _, name in
          guard let l = store.specs.first(where: { $0.name == name }) else { return }
          let copy = store.draft(for: l)
          draft.every = copy.every
          draft.windowed = copy.windowed
          draft.from = copy.from
          draft.until = copy.until
          draft.alone = copy.alone
          draft.model = copy.model
          draft.worktree = copy.worktree
          draft.steps = steps(of: name)
        }
      }
      Section {
        TextField("Name", text: $draft.title, prompt: Text("Coverage hunter"))
          .help("Shows in Loops and in notifications")
        if !draft.title.isEmpty && !titleOK {
          Label("Letters, numbers, spaces and & + . / - only.", icon: "exclamationmark.circle")
            .foregroundStyle(.red)
            .help("Use letters, numbers, spaces and & + . / -, starting with a letter or number.")
        }
        LabeledContent("ID") {
          HStack(spacing: 6) {
            Text(name).foregroundStyle(.secondary).textSelection(.enabled)
            if taken {
              Label("Already used", icon: "xmark.circle").foregroundStyle(.red)
            }
          }
        }
        TextField("What it does", text: $draft.description, prompt: Text("Daily loop. One line on what it does."), axis: .vertical)
          .lineLimit(2...4)
          .help("What each loop's page says it does")
        Picker("Group", selection: $draft.group) {
          ForEach(groupChoices, id: \.self) { Text($0).tag($0) }
          Divider()
          Text("Other").tag("")
        }
        if !groupChoices.contains(draft.group) && !draft.group.isEmpty || newGroup {
          TextField("New group", text: $draft.group, prompt: Text("Name a new group"))
        }
        Toggle("Start a new group", isOn: $newGroup.animation(.snappy))
      } header: {
        Text("Loop")
      }
      Section {
        Picker("Runs", selection: $draft.every) {
          Text("Hourly").tag(1)
          Text("2 hours").tag(2)
          Text("6 hours").tag(6)
          Text("Daily").tag(24)
          Text("Weekly").tag(168)
        }
        .pickerStyle(.segmented)
        .help("The runner ticks every hour and starts a loop once it is due")
        Toggle("Only during certain hours", isOn: $draft.windowed.animation(.snappy))
        if draft.windowed {
          LabeledContent("Between") {
            HStack(spacing: 6) {
              Picker("From", selection: $draft.from) {
                ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
              }
              .labelsHidden()
              .fixedSize()
              Text("and").foregroundStyle(.secondary)
              Picker("Until", selection: $draft.until) {
                ForEach(1..<25, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
              }
              .labelsHidden()
              .fixedSize()
            }
          }
          .help("Hours are \(store.project?.zone.identifier ?? TimeZone.current.identifier) time")
        }
        Toggle("Runs alone", isOn: $draft.alone)
          .help("Runs after the other loops of its tick")
      } header: {
        Text("Schedule")
      }
      Section {
        Picker("Model", selection: $draft.model) {
          ForEach(ClaudeApp.models, id: \.self) { Text($0.capitalized).tag($0) }
        }
        Toggle("Works in its own worktree", isOn: $draft.worktree)
          .help("Turn on for a loop that writes code or pushes branches")
      } header: {
        Text("Agent")
      }
      if case .add = mode {
        Section {
          TextField("What it ships", text: $draft.ships, prompt: Text("A PR per fix, a weekly report…"), axis: .vertical)
            .lineLimit(1...3)
          ZStack(alignment: .topLeading) {
            if draft.steps.isEmpty {
              Text("1. Read what changed since the last run.\n2. Do the one thing this loop owns.\n3. Return a short brief.")
                .font(.body.monospaced())
                .foregroundStyle(.tertiary)
                .padding(.top, 1)
                .allowsHitTesting(false)
            }
            TextEditor(text: $draft.steps)
              .font(.body.monospaced())
              .scrollContentBackground(.hidden)
              .frame(minHeight: 150)
          }
          .help("Steps are Markdown and become the Steps section of the loop's skill")
        } header: {
          Text("Work")
        }
      }
    }
    if let preview {
      Section("Changes") {
        ScrollView {
          Text(preview)
            .font(.callout.monospaced())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 200)
      }
    }
    if let error {
      Section {
        Label(error, icon: "exclamationmark.triangle")
          .foregroundStyle(.red)
          .lineLimit(2)
          .help(error)
      }
    }
    if let opened {
      Section {
        LabeledContent {
          Button("Open PR") { openURL(opened) }
        } label: {
          Label("Pull request opened", icon: "checkmark.circle")
        }
      }
    }
  }

  private func run(dry: Bool) async {
    busy = true
    error = nil
    var p = payload
    if dry { p["dry"] = true }
    let result = await store.admin(p)
    busy = false
    let lastErr = result.err.split(separator: "\n").last.map(String.init) ?? ""
    guard result.ok else {
      error = lastErr.isEmpty ? "loop-admin failed." : lastErr
      return
    }
    if dry {
      preview = result.out.isEmpty ? "No changes." : result.out
    } else if let line = result.out.split(separator: "\n").last, let url = URL(string: String(line)), url.scheme == "https" {
      opened = url
      await store.refreshGitHub()
    } else {
      error = "The pull request was made, but its link was not printed."
    }
  }
}

extension LoopEdit {
  var isRemove: Bool {
    if case .remove = self { return true }
    return false
  }
}
