import AppKit
import CryptoKit
import Foundation
import Observation

enum Mermaid {
  static func blocks(_ markdown: String) -> [String] {
    var out: [String] = []
    var fence: (char: Character, count: Int, indent: Int)?
    var mermaid = false
    var lines: [String] = []
    func close() {
      let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      if mermaid, !text.isEmpty { out.append(text) }
      fence = nil
      mermaid = false
      lines = []
    }
    let text = markdown.replacingOccurrences(of: "\r\n", with: "\n")
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let indent = raw.prefix { $0 == " " }.count
      let line = raw.dropFirst(indent)
      if let f = fence {
        let run = line.prefix { $0 == f.char }.count
        if indent < 4, run >= f.count, line.dropFirst(run).allSatisfy(\.isWhitespace) {
          close()
        } else if mermaid {
          lines.append(String(raw.dropFirst(min(indent, f.indent))))
        }
        continue
      }
      guard indent < 4, let c = line.first, c == "`" || c == "~" else { continue }
      let run = line.prefix { $0 == c }.count
      guard run >= 3 else { continue }
      let info = line.dropFirst(run).trimmingCharacters(in: .whitespaces)
      if c == "`", info.contains("`") { continue }
      fence = (c, run, indent)
      mermaid = info.split(separator: " ").first?.lowercased() == "mermaid"
    }
    if fence != nil { close() }
    return out
  }

  static func source(_ text: String) -> String {
    blocks(text).first ?? text.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

enum Statechart {
  static let script = ".claude/skills/statechart/scripts/statechart.mjs"

  static func key(_ source: String, theme: String) -> String {
    SHA256.hash(data: Data("\(theme)\n\(source)".utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
  }

  static func problem(_ output: String, code: Int32) -> String {
    let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    if code == 127 || lines.contains(where: { $0.hasPrefix("env: node") }) { return "Node isn't installed, so the chart can't be drawn" }
    if lines.contains(where: { $0.hasPrefix("cannot install") }) { return "Couldn't install the chart renderer with npm. Are you offline?" }
    guard var first = lines.first(where: { !$0.hasPrefix("Installing ") }) else { return "The renderer stopped with exit code \(code)" }
    if let r = first.range(of: #"^(could not render|cannot read|cannot write) [^:]+: "#, options: [.regularExpression, .caseInsensitive]) {
      first.removeSubrange(r)
    }
    if first.hasSuffix(":") { first.removeLast() }
    return capitalizedFirst(first)
  }
}

@MainActor @Observable
final class Statecharts {
  static let shared = Statecharts()

  enum Drawing: Equatable {
    case drawing
    case drawn(URL)
    case failed(String)
  }

  private(set) var drawings: [String: Drawing] = [:]
  private(set) var bodies: [Int: [String]] = [:]
  @ObservationIgnored private var images: [URL: NSImage] = [:]
  @ObservationIgnored private var fetching: Set<Int> = []

  private let folder: URL = {
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
    return caches.appending(path: Bundle.main.bundleIdentifier ?? "Loops").appending(path: "Statecharts")
  }()

  private func file(_ key: String) -> URL { folder.appending(path: "\(key).png") }

  func drawing(_ source: String, theme: String) -> Drawing? {
    let key = Statechart.key(source, theme: theme)
    if let d = drawings[key] { return d }
    let url = file(key)
    return FileManager.default.fileExists(atPath: url.path) ? .drawn(url) : nil
  }

  func image(_ url: URL) -> NSImage? {
    if let hit = images[url] { return hit }
    guard let image = NSImage(contentsOf: url), let rep = image.representations.first, rep.pixelsWide > 0 else { return nil }
    image.size = NSSize(width: CGFloat(rep.pixelsWide) / 2, height: CGFloat(rep.pixelsHigh) / 2)
    images[url] = image
    return image
  }

  func draw(_ source: String, theme: String, paths: Paths) async {
    let key = Statechart.key(source, theme: theme)
    switch drawing(source, theme: theme) {
    case .drawing?, .drawn?: return
    default: break
    }
    guard let script = paths.find(Statechart.script) else {
      drawings[key] = .failed("The statechart skill isn't in this checkout")
      return
    }
    drawings[key] = .drawing
    let fm = FileManager.default
    let work = fm.temporaryDirectory.appending(path: "loops-statechart-\(key)-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: work) }
    let input = work.appending(path: "chart.mmd")
    let output = work.appending(path: "chart.png")
    do {
      try fm.createDirectory(at: work, withIntermediateDirectories: true)
      try source.write(to: input, atomically: true, encoding: .utf8)
    } catch {
      drawings[key] = .failed(error.localizedDescription)
      return
    }
    let (code, out) = await Shell.exec(
      ["node", script.path, "render", input.path, "--theme", theme, "--out", output.path], in: work)
    let target = file(key)
    do {
      guard code == 0 else { throw CocoaError(.fileNoSuchFile) }
      try fm.createDirectory(at: folder, withIntermediateDirectories: true)
      if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
      try fm.moveItem(at: output, to: target)
      drawings[key] = .drawn(target)
    } catch {
      drawings[key] = .failed(code == 0 ? error.localizedDescription : Statechart.problem(out, code: code))
    }
  }

  func fetch(_ pr: Int, repo: URL) async {
    guard fetching.insert(pr).inserted else { return }
    defer { fetching.remove(pr) }
    let (code, out) = await Shell.exec(["gh", "pr", "view", String(pr), "--json", "body,headRefOid"], in: repo)
    guard code == 0, let start = out.firstIndex(of: "{"),
      let obj = (try? JSONSerialization.jsonObject(with: Data(out[start...].utf8))) as? [String: Any]
    else { return }
    let charts = Mermaid.blocks(obj["body"] as? String ?? "")
    if bodies[pr] != charts { bodies[pr] = charts }
  }
}
