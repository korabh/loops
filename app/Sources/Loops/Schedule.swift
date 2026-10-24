import Foundation

struct Tick: Identifiable {
  let at: Date
  let runs: [LoopSpec]

  var id: Date { at }
}

enum Schedule {
  static let slack: TimeInterval = 300

  static func calendar(_ zone: TimeZone) -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = zone
    return c
  }

  static func inHours(_ l: LoopSpec, at t: Date) -> Bool {
    guard let from = l.from, let until = l.until else { return true }
    let h = calendar(l.zone).component(.hour, from: t)
    return h >= from && h < until
  }

  static func opens(_ l: LoopSpec, after t: Date) -> Date? {
    guard let from = l.from else { return nil }
    return calendar(l.zone).nextDate(after: t, matching: DateComponents(hour: from, minute: 0), matchingPolicy: .nextTime)
  }

  static func period(_ l: LoopSpec) -> TimeInterval { Double(l.every) * 3600 }

  static func due(_ l: LoopSpec, last: Date?, at t: Date) -> Bool {
    guard inHours(l, at: t) else { return false }
    guard let last else { return true }
    return t.timeIntervalSince(last) >= period(l) - slack
  }

  static func overdue(_ l: LoopSpec, last: Date?, at t: Date) -> Double {
    guard let last else { return .infinity }
    return t.timeIntervalSince(last) / period(l)
  }

  static func pick(_ specs: [LoopSpec], last: [String: Date], at t: Date) -> [LoopSpec] {
    let ready = specs.filter { Schedule.due($0, last: last[$0.name], at: t) }
      .sorted { overdue($0, last: last[$0.name], at: t) > overdue($1, last: last[$1.name], at: t) }
    var batch: [LoopSpec] = []
    var weekly = 0
    for l in ready where !l.alone && batch.count < 4 {
      if l.weekly {
        if weekly > 0 { continue }
        weekly += 1
      }
      batch.append(l)
    }
    if let factory = ready.first(where: { $0.alone }) { batch.append(factory) }
    return batch
  }

  static func nextTick(after now: Date, recent: [Date], in zone: TimeZone) -> Date {
    let calendar = calendar(zone)
    let minutes = recent.filter { now.timeIntervalSince($0) < 12 * 3600 }.map { calendar.component(.minute, from: $0) }
    let counts = Dictionary(grouping: minutes, by: { $0 }).mapValues(\.count)
    guard let minute = counts.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) })?.key
    else { return now }
    return calendar.nextDate(after: now, matching: DateComponents(minute: minute), matchingPolicy: .nextTime) ?? now
  }

  static func forecast(_ specs: [LoopSpec], last: [String: Date], running: [String: Date], from first: Date, ticks: Int)
    -> [Tick]
  {
    var last = last
    for (name, started) in running { last[name] = started }
    var out: [Tick] = []
    for k in 0..<ticks {
      let t = first.addingTimeInterval(Double(k) * 3600)
      let runs = pick(specs, last: last, at: t)
      for l in runs { last[l.name] = t }
      if !runs.isEmpty { out.append(Tick(at: t, runs: runs)) }
    }
    return out
  }
}
