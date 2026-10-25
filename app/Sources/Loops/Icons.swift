import AppKit
import SwiftUI

enum Icons {
  static let names: [String: String] = [
    "ant": "bug", "arrow.clockwise": "arrow-clockwise", "arrow.counterclockwise": "arrow-counter-clockwise",
    "arrow.counterclockwise.circle": "clock-counter-clockwise", "arrow.forward.circle": "arrow-circle-right",
    "arrow.left.arrow.right": "arrows-left-right", "arrow.right": "arrow-right", "arrow.right.circle": "arrow-circle-right",
    "arrow.down": "arrow-down", "arrow.up": "arrow-up", "arrow.down.circle": "arrow-circle-down",
    "arrow.trianglehead.2.clockwise": "arrows-clockwise", "arrow.trianglehead.2.clockwise.rotate.90": "arrows-clockwise",
    "arrow.trianglehead.branch": "git-branch", "arrow.trianglehead.merge": "git-merge", "arrow.trianglehead.pull": "git-pull-request",
    "arrow.triangle.branch": "git-branch", "arrow.triangle.merge": "git-merge", "arrow.triangle.pull": "git-pull-request",
    "arrow.up.right": "arrow-up-right", "arrow.up.forward.square": "arrow-square-out", "arrow.up.forward.app": "arrow-square-out",
    "arrow.uturn.backward": "arrow-u-up-left", "arrowshape.turn.up.left": "arrow-bend-up-left",
    "bell": "bell", "bell.fill": "bell-ringing", "bell.badge": "bell-ringing", "calendar": "calendar",
    "calendar.badge.clock": "calendar-dots", "chart.bar.xaxis": "chart-bar", "chart.bar": "chart-bar",
    "chart.line.uptrend.xyaxis": "chart-line-up", "chart.xyaxis.line": "chart-line", "checklist": "list-checks",
    "checklist.checked": "list-checks", "checkmark": "check", "checkmark.circle": "check-circle", "checkmark.circle.fill": "check-circle",
    "checkmark.seal": "seal-check", "checkmark.shield": "shield-check", "checkmark.square": "check-square",
    "chevron.down": "caret-down", "chevron.right": "caret-right", "chevron.up": "caret-up", "chevron.left": "caret-left",
    "circle": "circle", "circle.dashed": "circle-dashed", "circle.dotted": "circle-dashed", "circle.grid.2x2": "squares-four",
    "circle.lefthalf.filled": "circle-half", "clock": "clock", "clock.arrow.circlepath": "clock-counter-clockwise", "cpu": "cpu",
    "creditcard": "credit-card", "doc": "file", "doc.on.doc": "copy", "doc.text": "file-text",
    "doc.text.magnifyingglass": "file-magnifying-glass", "dollarsign": "currency-dollar", "dollarsign.circle": "currency-circle-dollar",
    "ellipsis": "dots-three", "ellipsis.circle": "dots-three-circle", "envelope": "envelope", "eraser": "eraser",
    "exclamationmark.circle": "warning-circle", "exclamationmark.octagon": "warning-octagon", "exclamationmark.triangle": "warning",
    "exclamationmark.triangle.fill": "warning", "eye": "eye", "eye.slash": "eye-slash", "flag": "flag", "folder": "folder",
    "folder.badge.plus": "folder-plus", "gauge.with.dots.needle.33percent": "gauge", "gauge.with.dots.needle.50percent": "gauge",
    "gauge.with.needle": "gauge", "gearshape": "gear", "globe": "globe", "hammer": "hammer", "hand.raised": "hand",
    "hand.thumbsup": "thumbs-up", "hand.thumbsdown": "thumbs-down", "heart.text.square": "heartbeat", "hourglass": "hourglass",
    "info.circle": "info", "key": "key", "largecircle.fill.circle": "radio-button", "smallcircle.circle": "radio-button",
    "leaf": "leaf", "light.beacon.max": "broadcast", "light.beacon.min": "radio-button", "lightbulb": "lightbulb",
    "line.3.horizontal.decrease.circle": "funnel", "line.3.horizontal.decrease.circle.fill": "funnel", "link": "link",
    "list.bullet": "list-bullets", "lock": "lock", "lock.shield": "lock", "macwindow": "app-window", "magnifyingglass": "magnifying-glass",
    "map": "map-trifold", "minus": "minus", "minus.circle": "minus-circle", "moon": "moon", "moon.zzz": "moon-stars", "number": "hash",
    "paintbrush.pointed": "palette", "paperplane": "paper-plane-tilt", "paperplane.fill": "paper-plane-tilt",
    "pause.circle": "pause-circle", "pencil": "pencil-simple", "person": "user", "person.3": "users-three",
    "person.crop.circle": "user-circle", "person.fill": "user", "pin": "push-pin", "play": "play", "play.circle": "play-circle",
    "play.fill": "play", "plus": "plus", "plus.circle": "plus-circle", "point.topleft.down.to.point.bottomright.curvepath": "path",
    "power": "power", "questionmark.bubble": "chat-circle-dots", "questionmark.circle": "question", "quote.opening": "quotes",
    "rectangle.stack": "stack", "scope": "crosshair", "server.rack": "hard-drives", "shield": "shield", "shippingbox": "package",
    "slash.circle": "prohibit", "slider.horizontal.3": "sliders-horizontal", "sparkle": "sparkle", "sparkles": "sparkle",
    "square": "square", "square.and.arrow.up": "export", "square.and.pencil": "note-pencil", "square.grid.2x2": "squares-four",
    "square.stack.3d.up": "stack-simple", "star": "star", "stop": "stop", "stop.circle": "stop-circle", "stop.fill": "stop",
    "stopwatch": "timer", "sun.max": "sun", "tag": "tag", "terminal": "terminal-window", "text.book.closed": "book-open-text",
    "text.bubble": "chat-text", "bubble.left": "chat", "timer": "timer", "trash": "trash", "tray": "tray", "tray.full": "tray",
    "tray.and.arrow.down": "tray-arrow-down", "tray.and.arrow.up": "tray-arrow-up", "wand.and.sparkles": "magic-wand",
    "waveform": "waveform", "wrench.adjustable": "wrench", "wrench.and.screwdriver": "wrench", "xmark": "x",
    "xmark.circle": "x-circle", "xmark.circle.fill": "x-circle", "bolt": "lightning",
  ]

  @MainActor private static var cache: [String: NSImage] = [:]

  static func resolve(_ symbol: String) -> String { names[symbol] ?? symbol }

  @MainActor static func image(_ symbol: String, size: CGFloat) -> NSImage? {
    let name = resolve(symbol)
    let key = "\(name)@\(size)"
    if let hit = cache[key] { return hit }
    guard let d = PhosphorData.paths[name] else { return nil }
    let path = CGMutablePath()
    for op in parse(d) {
      switch op.kind {
      case "M": path.move(to: op.points[0])
      case "L": path.addLine(to: op.points[0])
      case "C": path.addCurve(to: op.points[2], control1: op.points[0], control2: op.points[1])
      default: path.closeSubpath()
      }
    }
    let image = NSImage(size: NSSize(width: size, height: size))
    for scale in [1.0, 2.0, 3.0] {
      let px = Int((size * scale).rounded())
      guard
        let ctx = CGContext(
          data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { continue }
      ctx.translateBy(x: 0, y: CGFloat(px))
      ctx.scaleBy(x: CGFloat(px) / 256, y: -CGFloat(px) / 256)
      ctx.addPath(path)
      ctx.setFillColor(CGColor(gray: 0, alpha: 1))
      ctx.fillPath()
      guard let cg = ctx.makeImage() else { continue }
      let rep = NSBitmapImageRep(cgImage: cg)
      rep.size = NSSize(width: size, height: size)
      image.addRepresentation(rep)
    }
    image.isTemplate = true
    image.accessibilityDescription = name.replacingOccurrences(of: "-", with: " ")
    cache[key] = image
    return image
  }

  private struct Op {
    let kind: Character
    let points: [CGPoint]
  }

  private static func parse(_ d: String) -> [Op] {
    var ops: [Op] = []
    var kind: Character = "M"
    var nums: [CGFloat] = []
    var started = false
    func emit() {
      if kind == "Z" {
        ops.append(Op(kind: "Z", points: []))
      } else {
        let n = kind == "C" ? 6 : 2
        var i = 0
        while i + n <= nums.count {
          ops.append(Op(kind: kind, points: stride(from: i, to: i + n, by: 2).map { CGPoint(x: nums[$0], y: nums[$0 + 1]) }))
          i += n
        }
      }
      nums = []
    }
    for part in d.split(separator: " ") {
      if let c = part.first, c.isLetter {
        if started { emit() }
        started = true
        kind = c
        if let v = Double(part.dropFirst()) { nums.append(CGFloat(v)) }
      } else if let v = Double(part) {
        nums.append(CGFloat(v))
      }
    }
    if started { emit() }
    return ops
  }
}

extension Image {
  @MainActor init(icon symbol: String, size: CGFloat = 16) {
    if let image = Icons.image(symbol, size: size) {
      self = Image(nsImage: image).renderingMode(.template)
    } else {
      self = Image(systemName: symbol)
    }
  }
}

extension Label where Title == Text, Icon == Image {
  @MainActor init<S: StringProtocol>(_ title: S, icon symbol: String, size: CGFloat = 16) {
    self.init { Text(title) } icon: { Image(icon: symbol, size: size) }
  }
}

extension SidebarRowSize {
  var icon: CGFloat {
    switch self {
    case .small: 14
    case .large: 20
    default: 16
    }
  }
}

extension EnvironmentValues {
  @Entry var iconSize: CGFloat = 14
}

struct RowIcon: View {
  @Environment(\.iconSize) private var size
  let symbol: String

  var body: some View {
    Image(icon: symbol, size: size)
  }
}

extension Button where Label == SwiftUI.Label<Text, Image> {
  @MainActor init<S: StringProtocol>(_ title: S, icon symbol: String, role: ButtonRole? = nil, action: @escaping @MainActor () -> Void) {
    self.init(role: role, action: action) { SwiftUI.Label(title, icon: symbol) }
  }
}
