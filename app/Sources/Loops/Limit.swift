import SwiftUI

struct UsageLimit: Equatable, Codable {
  let text: String
  let at: Date?
  let resets: Date?

  var kind: String {
    Reader.groups(#"your ([a-zA-Z0-9 -]+?) limit"#, in: text).first.map { "\($0) limit" } ?? "usage limit"
  }

  static func reached(_ text: String) -> Bool {
    text.range(of: #"(?i)((hit|reached) your|usage) [a-z0-9 -]*limit"#, options: .regularExpression) != nil
  }

  static func resets(in text: String, after base: Date) -> Date? {
    guard
      let re = try? Regex(#"resets (?:([A-Z][a-z]{2,8})\.? (\d{1,2}),? (?:at )?)?(\d{1,2})(?::(\d{2}))? ?([ap]m) \(([^)]+)\)"#),
      let m = text.firstMatch(of: re)
    else { return nil }
    let part = { (i: Int) in m.output[i].substring.map(String.init) }
    guard let h = part(3).flatMap(Int.init), let ampm = part(5), let zone = part(6).flatMap(TimeZone.init(identifier:)) else { return nil }
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = zone
    let hour = h % 12 + (ampm == "pm" ? 12 : 0)
    let minute = part(4).flatMap(Int.init) ?? 0
    if let month = part(1).flatMap(monthIndex), let day = part(2).flatMap(Int.init) {
      var c = DateComponents(year: cal.component(.year, from: base), month: month, day: day, hour: hour, minute: minute)
      guard var d = cal.date(from: c) else { return nil }
      if d < base {
        c.year = (c.year ?? 0) + 1
        d = cal.date(from: c) ?? d
      }
      return d
    }
    guard let today = cal.date(bySettingHour: hour, minute: minute, second: 0, of: base) else { return nil }
    return today > base ? today : cal.date(byAdding: .day, value: 1, to: today)
  }

  private static func monthIndex(_ s: String) -> Int? {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    return (f.shortMonthSymbols.firstIndex { s.hasPrefix($0) } ?? f.monthSymbols.firstIndex { s == $0 }).map { $0 + 1 }
  }

  static func read(config: String, runner: URL) -> UsageLimit? {
    let dir = URL(fileURLWithPath: config).appending(path: "projects/\(Spend.slug(runner.path))")
    let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    let modified = { (u: URL) in (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast }
    guard let latest = files.filter({ $0.pathExtension == "jsonl" }).max(by: { modified($0) < modified($1) }) else { return nil }
    return last(in: latest)
  }

  static func last(in url: URL) -> UsageLimit? {
    guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? h.close() }
    let size = (try? h.seekToEnd()) ?? 0
    try? h.seek(toOffset: size > 256 * 1024 ? size - 256 * 1024 : 0)
    let tail = String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
    let last = tail.split(separator: "\n").reversed().lazy
      .compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
      .first { ["assistant", "user"].contains($0["type"] as? String ?? "") }
    guard let last, last["isApiErrorMessage"] as? Bool == true, last["error"] as? String == "rate_limit" else { return nil }
    let content = ((last["message"] as? [String: Any])?["content"] as? [[String: Any]])?.first
    let text = content?["text"] as? String ?? "Usage limit reached"
    let at = (last["timestamp"] as? String).flatMap(Reader.date)
    return UsageLimit(text: text, at: at, resets: resets(in: text, after: at ?? Date()))
  }
}

extension Store {
  var limitLifted: Bool {
    guard let at = limit?.at else { return false }
    let own = runner?.session?.id
    return jobs.jobs.values.contains { $0.id != own && $0.state == "working" && $0.updated > at.addingTimeInterval(60) }
  }

  var resumeScript: URL? {
    (Reader.text(paths.script) ?? "").contains("  resume)") ? paths.script : nil
  }

  func resume() {
    guard let script = resumeScript, action == nil else {
      notice = "This build of Loops has no loop-runner resume command."
      return
    }
    action = "Resuming…"
    notice = nil
    Task {
      let (code, out) = await Shell.run(script, ["resume"], in: paths.repo)
      action = nil
      if code != 0 { notice = out.trimmingCharacters(in: .whitespacesAndNewlines) }
      reload()
      await refreshRunner()
    }
  }

  static let afterLimit = "The usage limit has reset. Pick the task up where you stopped."

  func taskLimit(_ t: BgTask) -> UsageLimit? {
    transcript(t).flatMap(UsageLimit.last(in:))
  }

  func resumeTask(_ t: BgTask, auto: Bool = false) {
    reply(t, Store.afterLimit, resumes: (t.resumes ?? 0) + (auto ? 1 : 0))
  }

  func resumeLimited() {
    for t in tasks where !t.active && (t.resumes ?? 0) < 2 && !asking.contains("reply:\(t.id)") {
      guard let resets = t.limit?.resets, resets.addingTimeInterval(60) <= Date() else { continue }
      resumeTask(t, auto: true)
    }
  }

  func noticeLimit(from old: UsageLimit?, to new: UsageLimit?) {
    limit = new
    if let new, old == nil, Date().timeIntervalSince(new.at ?? .distantPast) < 15 * 60 {
      let back = new.resets.map { " Loops are back at \(Clock.day($0, now: Date()))." } ?? ""
      notify(title: "Loops paused: \(new.kind)", body: "\(account?.email ?? "The runner's account") hit its \(new.kind).\(back)")
    } else if new == nil, old != nil {
      notify(title: "Loops are running again", body: "The usage limit reset. The runner picks up at its next tick.")
    }
  }
}
