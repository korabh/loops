import AppKit
import SwiftUI

struct AppIcon: View {
  private func color(_ l: Double, _ c: Double, _ h: Double) -> Color {
    let v = l * l * l
    return Color(.sRGB, white: v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055)
  }

  var body: some View {
    let tile = RoundedRectangle(cornerRadius: 186, style: .continuous)
    ZStack {
      tile
        .fill(LinearGradient(colors: [color(0.3, 0, 0), color(0.13, 0, 0)], startPoint: .top, endPoint: .bottom))
      tile
        .fill(LinearGradient(colors: [.white.opacity(0.1), .clear], startPoint: .top, endPoint: .center))
      Canvas { g, size in draw(&g, size) }
      tile.strokeBorder(.white.opacity(0.08), lineWidth: 3)
    }
    .frame(width: 824, height: 824)
    .clipShape(tile)
    .frame(width: 1024, height: 1024)
  }

  private func draw(_ g: inout GraphicsContext, _ size: CGSize) {
    let c = CGPoint(x: size.width / 2, y: size.height / 2)
    let point = { (r: CGFloat, deg: Double) in
      CGPoint(x: c.x + r * CGFloat(sin(deg * .pi / 180)), y: c.y - r * CGFloat(cos(deg * .pi / 180)))
    }
    let ringRadius: CGFloat = 290
    let gap = 26.0

    var beam = Path()
    beam.move(to: c)
    for d in stride(from: -gap, through: gap, by: 1) { beam.addLine(to: point(420, d)) }
    beam.closeSubpath()
    g.drawLayer { layer in
      layer.addFilter(.blur(radius: 26))
      layer.fill(
        beam,
        with: .radialGradient(
          Gradient(colors: [color(0.95, 0, 0).opacity(0), color(0.95, 0, 0).opacity(0.3)]), center: c,
          startRadius: 110, endRadius: 420))
    }

    var ring = Path()
    ring.move(to: point(ringRadius, gap))
    for d in stride(from: gap, through: 360 - gap, by: 1) { ring.addLine(to: point(ringRadius, d)) }
    let grays = Array(stride(from: 0.5, through: 0.94, by: 0.04))
    g.drawLayer { layer in
      layer.addFilter(.shadow(color: .black.opacity(0.45), radius: 22, x: 0, y: 12))
      layer.stroke(
        ring,
        with: .conicGradient(
          Gradient(colors: grays.map { color($0, 0, 0) }), center: c, angle: .degrees(-90 + gap * 0.6)),
        style: StrokeStyle(lineWidth: 64, lineCap: .round))
    }

    let head = point(ringRadius, 360 - gap)
    g.fill(
      Path(ellipseIn: CGRect(x: head.x - 70, y: head.y - 70, width: 140, height: 140)),
      with: .radialGradient(
        Gradient(colors: [color(0.97, 0, 0).opacity(0.7), color(0.97, 0, 0).opacity(0)]), center: head,
        startRadius: 10, endRadius: 70))
    g.fill(
      Path(ellipseIn: CGRect(x: head.x - 30, y: head.y - 30, width: 60, height: 60)),
      with: .color(color(0.98, 0, 0)))

  }

  @MainActor static func write(to path: String) -> Bool {
    let renderer = ImageRenderer(content: AppIcon())
    renderer.scale = 1
    guard let image = renderer.cgImage else { return false }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let png = rep.representation(using: .png, properties: [:]) else { return false }
    return (try? png.write(to: URL(fileURLWithPath: path))) != nil
  }
}

enum MenuGlyph {
  private static let idle = draw(working: false, badge: false)
  private static let working = draw(working: true, badge: false)
  private static let idleBadged = draw(working: false, badge: true)
  private static let workingBadged = draw(working: true, badge: true)

  static func image(working: Bool, badge: Bool) -> NSImage {
    working ? (badge ? workingBadged : self.working) : (badge ? idleBadged : idle)
  }

  private static func draw(working: Bool, badge: Bool) -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
      NSColor.black.setStroke()
      NSColor.black.setFill()
      let c = NSPoint(x: 9, y: 9)
      let r: CGFloat = 7
      let gap: CGFloat = 28
      let ring = NSBezierPath()
      ring.lineWidth = 1.7
      ring.lineCapStyle = .round
      ring.appendArc(withCenter: c, radius: r, startAngle: 90 - gap, endAngle: 90 + gap, clockwise: true)
      ring.stroke()
      if working {
        let a = (90 + gap) * .pi / 180
        let head = NSPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
        NSBezierPath(ovalIn: NSRect(x: head.x - 2.2, y: head.y - 2.2, width: 4.4, height: 4.4)).fill()
      }
      if badge {
        let dot = NSRect(x: 11.4, y: 0.4, width: 6.2, height: 6.2)
        NSGraphicsContext.current?.compositingOperation = .clear
        NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        NSBezierPath(ovalIn: dot).fill()
      }
      return true
    }
    image.isTemplate = true
    return image
  }
}
