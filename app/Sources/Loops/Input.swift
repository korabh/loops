import SwiftUI

struct Choice: Equatable, Identifiable {
  let label: String
  let reply: String
  var note: String?

  var id: String { label }
}

struct PendingInput: Equatable {
  let title: String
  let detail: String?
  let options: [String]
  var recommended: String?
  var notes: [String: String] = [:]

  var choices: [Choice] {
    options.map { o in
      let label = o.replacingOccurrences(of: " (Recommended)", with: "", options: .caseInsensitive)
      return Choice(label: label, reply: label, note: notes[o])
    }
  }

  nonisolated(unsafe) private static var cache: [String: (Int, PendingInput?)] = [:]
  private static let lock = NSLock()

  static func read(_ url: URL, waitingFor: String?) -> PendingInput? {
    let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
    guard size > 0 else { return nil }
    lock.lock()
    defer { lock.unlock() }
    if let hit = cache[url.path], hit.0 == size { return hit.1 }
    guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? h.close() }
    try? h.seek(toOffset: size > 512 * 1024 ? UInt64(size - 512 * 1024) : 0)
    let text = String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
    var calls: [(id: String, name: String, input: [String: Any])] = []
    var answered = Set<String>()
    var said: String?
    for line in text.split(separator: "\n") {
      guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
        let message = obj["message"] as? [String: Any], let content = message["content"] as? [[String: Any]]
      else { continue }
      for item in content {
        switch item["type"] as? String {
        case "tool_use":
          if let id = item["id"] as? String { calls.append((id, item["name"] as? String ?? "", item["input"] as? [String: Any] ?? [:])) }
          said = nil
        case "tool_result":
          if let id = item["tool_use_id"] as? String { answered.insert(id) }
        case "text" where obj["type"] as? String == "assistant":
          if let t = item["text"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { said = t }
        default:
          break
        }
      }
    }
    let found = calls.last { !answered.contains($0.id) }.map(describe) ?? said.map(question)
    cache[url.path] = (size, found)
    return found
  }

  static func screen(_ raw: String) -> PendingInput? {
    let plain = raw.replacingOccurrences(of: #"\x1B\[[0-9;?]*[ -/]*[@-~]"#, with: "\n", options: .regularExpression)
      .replacingOccurrences(of: #"\x1B[\]P][^\x07]*\x07"#, with: "", options: .regularExpression)
    let lines = plain.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    guard let first = lines.lastIndex(where: { $0.range(of: #"^(❯\s*)?1\."#, options: .regularExpression) != nil }) else { return nil }
    var question: [String] = []
    var header: String?
    var i = first - 1
    while i >= 0 {
      let l = lines[i]
      if l.hasPrefix("☐") || l.hasPrefix("☒") { header = String(l.dropFirst()).trimmingCharacters(in: .whitespaces); break }
      if l.hasPrefix("──") { break }
      if l != "❯" { question.insert(l, at: 0) }
      i -= 1
    }
    var options: [String] = []
    var notes: [String: String] = [:]
    var label: [String] = []
    var note: [String] = []
    var expectLabel = false
    func close() {
      guard !label.isEmpty else { return }
      let l = label.joined(separator: " ")
      options.append(l)
      if !note.isEmpty { notes[l] = note.joined(separator: " ") }
    }
    for l in lines[first...] {
      if l.hasPrefix("Enter to select") || l.hasPrefix("──") { break }
      let m = Reader.groups(#"^(?:❯\s*)?(\d+)\.\s*(.*)$"#, in: l)
      if m.count == 2 {
        close()
        label = m[1].isEmpty ? [] : [m[1]]
        note = []
        expectLabel = m[1].isEmpty
        continue
      }
      if expectLabel {
        label.append(l)
        expectLabel = false
      } else if !label.isEmpty, l != "❯" {
        note.append(l)
      }
    }
    close()
    options = options.filter { !["Type something.", "Chat about this"].contains($0) }
    guard !question.isEmpty || !options.isEmpty else { return nil }
    return PendingInput(
      title: question.joined(separator: " ").isEmpty ? "It needs your answer to continue" : question.joined(separator: " "), detail: header,
      options: options, recommended: options.first { $0.localizedCaseInsensitiveContains("recommended") } ?? options.first, notes: notes)
  }

  private static func question(_ text: String) -> PendingInput {
    let paragraphs = text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    let ask = paragraphs.last { $0.contains("?") } ?? paragraphs.last ?? text
    let before = paragraphs.prefix { $0 != ask }.suffix(2).joined(separator: "\n\n")
    return PendingInput(title: String(ask.prefix(400)), detail: before.isEmpty ? nil : String(before.suffix(600)), options: [])
  }

  private static func describe(_ call: (id: String, name: String, input: [String: Any])) -> PendingInput {
    if call.name == "AskUserQuestion", let q = (call.input["questions"] as? [[String: Any]])?.first {
      let options = (q["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
      let pick = options.first { $0.localizedCaseInsensitiveContains("recommended") } ?? options.first
      return PendingInput(
        title: q["question"] as? String ?? "It has a question", detail: q["header"] as? String, options: options, recommended: pick)
    }
    if call.name == "ExitPlanMode" {
      return PendingInput(
        title: "It wants you to approve its plan", detail: (call.input["plan"] as? String).map { String($0.prefix(400)) },
        options: ["Approve the plan and go ahead", "Revise the plan first"], recommended: "Approve the plan and go ahead")
    }
    if call.name == "Bash", let command = call.input["command"] as? String {
      return PendingInput(
        title: "It wants to run a command", detail: (call.input["description"] as? String) ?? String(command.prefix(240)),
        options: ["Go ahead", "Don't run it; find another way"], recommended: "Go ahead")
    }
    if let path = (call.input["file_path"] as? String) ?? (call.input["notebook_path"] as? String) {
      return PendingInput(
        title: "It wants to \(call.name == "Read" ? "read" : "change") \((path as NSString).lastPathComponent)", detail: path,
        options: ["Go ahead", "Leave that file alone"], recommended: "Go ahead")
    }
    let name = call.name.replacingOccurrences(of: "mcp__", with: "").replacingOccurrences(of: "_", with: " ")
    return PendingInput(title: "It wants to use \(name)", detail: nil, options: ["Go ahead", "Skip it"], recommended: "Go ahead")
  }
}

@MainActor @Observable
final class Suggester {
  static let shared = Suggester()

  private(set) var replies: [String: [Choice]] = [:]
  private(set) var screens: [String: PendingInput] = [:]
  private var asked = Set<String>()

  func screen(_ t: BgTask, store: Store) async {
    let (_, out) = await Shell.exec(["claude", "logs", t.id], in: store.paths.repo, config: store.config)
    if let found = PendingInput.screen(out), screens[t.id] != found { screens[t.id] = found }
  }

  private static let schema =
    #"{"type":"object","additionalProperties":false,"required":["replies"],"properties":{"replies":{"type":"array","maxItems":3,"items":{"type":"object","additionalProperties":false,"required":["label","reply"],"properties":{"label":{"type":"string"},"reply":{"type":"string"}}}}}}"#

  func load(_ key: String, _ input: PendingInput, store: Store) async {
    guard input.options.isEmpty, !asked.contains(key) else { return }
    asked.insert(key)
    let prompt =
      "A coding agent working in the background stopped and asked its user this:\n\n\(input.detail.map { $0 + "\n\n" } ?? "")\(input.title)\n\nSuggest up to three replies the user could send, the one you would recommend first. Give each a label of two to four plain words (like 'File both issues' or 'Leave it for now') and a reply: one short sentence the agent can act on without asking again. No code formatting."
    let (_, out) = await Shell.exec(
      [
        "claude", "-p", "--model", "haiku", "--effort", "low", "--output-format", "json", "--json-schema", Self.schema,
        "--disable-slash-commands", prompt,
      ], in: store.paths.repo, config: store.config)
    let json = out.split(separator: "\n").last { $0.hasPrefix("{") }.map(String.init) ?? ""
    let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
    let list = ((obj?["structured_output"] as? [String: Any])?["replies"] as? [[String: Any]]) ?? []
    let r = list.compactMap { d -> Choice? in
      guard let label = d["label"] as? String, let reply = d["reply"] as? String else { return nil }
      return Choice(label: label, reply: reply, note: reply == label ? nil : reply)
    }
    if !r.isEmpty { replies[key] = r }
  }
}

extension BgTask {
  var needsYou: Bool { limit == nil && (waitingFor != nil || state == "blocked") }
}

extension Store {
  static let unattended =
    "You were started from the Loops app and run in the background with nobody watching. Don't stop to ask questions or wait for approval: take the choice the repo's conventions point to, say in your final message what you chose and why, and end with any question that truly needs a person."

  var needsInput: [BgTask] { tasks.filter(\.needsYou) }

  func reply(_ t: BgTask, _ answer: String, resumes: Int? = nil) {
    guard let sid = t.sessionId, let cwd = t.cwd, !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    let key = "reply:\(t.id)"
    let question = t.needsYou ? pendingInput(t)?.title ?? t.waitingFor.map { "It is waiting for \($0)" } ?? "" : nil
    asking.insert(key)
    notice = nil
    let dir = URL(fileURLWithPath: cwd)
    Task {
      _ = await Shell.exec(["claude", "stop", t.id], in: dir, config: config)
      let (code, out) = await Shell.exec(
        [
          "claude", "--bg", "--resume", sid, "--name", t.title, "--permission-mode", "auto", "--append-system-prompt", Store.unattended,
        ] + hookArgs + [answer], in: dir, config: config)
      asking.remove(key)
      let id = Reader.groups(#"backgrounded · ([0-9a-f]+)"#, in: out).first ?? Reader.groups(#"claude attach ([0-9a-f]+)"#, in: out).first
      guard code == 0, let id else {
        notice = "Could not send the answer: \(out.trimmingCharacters(in: .whitespacesAndNewlines).suffix(300))"
        return
      }
      if let question { recordAnswer(loop: t.loop, task: t.title, question: question, answer: answer, source: "session") }
      if let i = tasks.firstIndex(where: { $0.id == t.id }) {
        tasks[i] = t.resumed(as: id, resumes: resumes)
      }
      for (k, v) in started where v == t.id { started[k] = id }
      saveTasks()
      await jobs.reconcile()
      refreshTasks()
    }
  }

  func queue(_ t: BgTask, _ text: String) {
    queued[t.stable] = text
    defaults.set(queued, forKey: "queuedFollowUps")
  }

  func unqueue(_ t: BgTask) {
    queued[t.stable] = nil
    defaults.set(queued, forKey: "queuedFollowUps")
  }

  func sendQueued() {
    for t in tasks where !t.running && t.limit == nil && t.sessionId != nil && t.cwd != nil && !asking.contains("reply:\(t.id)") {
      guard let text = queued[t.stable] else { continue }
      unqueue(t)
      reply(t, text)
    }
  }

  func pendingInput(_ t: BgTask) -> PendingInput? {
    guard t.needsYou else { return nil }
    if let url = transcript(t), let found = PendingInput.read(url, waitingFor: t.waitingFor) { return found }
    return Suggester.shared.screens[t.id] ?? t.waitingFor.map { PendingInput(title: "It is waiting for \($0)", detail: nil, options: []) }
  }
}
