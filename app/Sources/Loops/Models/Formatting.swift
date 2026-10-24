import AppKit
import SwiftUI

enum Appearance: String, CaseIterable, Identifiable {
  case system, light, dark

  var id: String { rawValue }
  var title: String { rawValue.capitalized }

  var nsAppearance: NSAppearance? {
    switch self {
    case .system: nil
    case .light: NSAppearance(named: .aqua)
    case .dark: NSAppearance(named: .darkAqua)
    }
  }
}

enum Clock {
  private static let hm: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    return f
  }()

  private static let dhm: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "EEE HH:mm"
    return f
  }()

  static func time(_ d: Date) -> String { hm.string(from: d) }

  static func day(_ d: Date, now: Date) -> String {
    Calendar.current.isDate(d, inSameDayAs: now) ? hm.string(from: d) : dhm.string(from: d)
  }

  static func span(_ seconds: TimeInterval) -> String {
    let m = Int(max(0, seconds) / 60)
    if m < 60 { return "\(m)m" }
    let h = m / 60
    if h < 10 { return m % 60 == 0 ? "\(h)h" : "\(h)h \(m % 60)m" }
    if h < 48 { return "\(h)h" }
    return "\(h / 24)d"
  }

  static func ago(_ d: Date, now: Date) -> String { "\(span(now.timeIntervalSince(d))) ago" }

  static func short(_ seconds: TimeInterval) -> String {
    let m = Int(max(0, seconds) / 60)
    if m < 60 { return "\(m)m" }
    if m < 48 * 60 { return "\(Int((Double(m) / 60).rounded()))h" }
    return "\(Int((Double(m) / 1440).rounded()))d"
  }

  static func until(_ d: Date, now: Date) -> String {
    d <= now ? "now" : "in \(span(d.timeIntervalSince(now)))"
  }
}

func joined(_ items: [String]) -> String {
  ListFormatter.localizedString(byJoining: items)
}

func plural(_ n: Int, _ one: String, _ many: String? = nil) -> String {
  n == 1 ? "1 \(one)" : "\(n) \(many ?? one + "s")"
}

extension Double {
  var usdShort: String {
    if self == 0 { return "$0" }
    if self >= 1000 { return "$" + (self / 1000).formatted(.number.precision(.fractionLength(0...1))) + "k" }
    if self >= 10 { return "$" + self.formatted(.number.precision(.fractionLength(0))) }
    return "$" + self.formatted(.number.precision(.fractionLength(0...2)))
  }
}

extension Tokens {
  var spent: String { "\(cost.usd) · \(total.compact) tokens" }
}

enum Symbols {
  static let openOnGitHub = "arrow.up.right"
  static let askClaude = "asterisk"
  static let goal = "flag"
  static let more = "ellipsis"
  static let billing = "creditcard"

  static var custom: [String: String] = [:]

  static func loop(_ name: String) -> String {
    if let symbol = custom[name] { return symbol }
    return switch name {
    case "loop-green-main": "checkmark.shield"
    case "loop-prod-errors": "ant"
    case "loop-issue-queue": "hammer"
    case "loop-pr-review": "eye"
    case "loop-pr-fix": "wrench.adjustable"
    case "loop-convex-review": "lock.shield"
    case "loop-tests": "scope"
    case "loop-dep-drift": "shippingbox"
    case "loop-convex-cost": "dollarsign.circle"
    case "loop-correct": "arrow.uturn.backward"
    case "loop-parked-branches": "arrow.trianglehead.branch"
    default: "circle.dashed"
    }
  }
}

enum ClaudeApp {
  static let models = ["fable", "opus", "sonnet", "haiku"]
}

struct LoopGroup: Identifiable {
  let name: String
  let loops: [LoopSpec]

  var id: String { name }
}

enum Groups {
  static let order = ["Ship", "Guard", "Tidy", "Watch"]

  static func symbol(_ group: String) -> String {
    switch group {
    case "Ship": "paperplane"
    case "Guard": "shield"
    case "Tidy": "wand.and.sparkles"
    case "Watch": "chart.line.uptrend.xyaxis"
    case "Other": "folder"
    default: "rectangle.stack"
    }
  }

  static func rank(_ group: String) -> (Int, String) {
    if let i = order.firstIndex(of: group) { return (i, group) }
    return group == "Other" ? (Int.max, group) : (order.count, group)
  }
}
