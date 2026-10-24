import Foundation

enum Briefs {
  private static let link = try! Regex(#"(?:claude-cli|https?)://[^\s<>]+"#)
  private static let cli = try! Regex(#"claude-cli://[^\s<>]+"#)
  private static let markers = ["Needs a person:", "Decision:"]

  static func trimmed(_ url: String) -> String {
    var u = Substring(url)
    while let c = u.last, ".,;:)".contains(c) { u = u.dropLast() }
    return String(u)
  }

  static func label(_ url: String) -> String {
    if url.hasPrefix("claude-cli://") { return "Open in Claude Code" }
    if let n = Reader.groups(#"github\.com/[^/]+/[^/]+/(?:pull|issues)/(\d+)"#, in: url).first { return "#\(n)" }
    if url.contains("app.asana.com") { return "Asana task" }
    return URL(string: url)?.host() ?? url
  }

  nonisolated(unsafe) static var names: [String: String] = [:]

  enum Part {
    case text(String)
    case bullets(String?, [String])
    case action(String)
  }

  private static let verbs = ["Decide", "Merge", "Review", "Fix", "Rebase", "Re-run", "Rerun", "File", "Answer", "Check", "Confirm"]

  static func split(_ s: String, on separator: String) -> [String] {
    var out: [String] = []
    var depth = 0
    var current = ""
    var i = s.startIndex
    while i < s.endIndex {
      let c = s[i]
      if c == "(" { depth += 1 } else if c == ")" { depth = max(0, depth - 1) }
      if depth == 0, s[i...].hasPrefix(separator) {
        out.append(current)
        current = ""
        i = s.index(i, offsetBy: separator.count)
        continue
      }
      current.append(c)
      i = s.index(after: i)
    }
    out.append(current)
    return out.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
  }

  static func structure(_ text: String) -> [Part] {
    var parts: [Part] = []
    for raw in sentences(readable(text)) {
      let s = raw.hasSuffix(".") ? String(raw.dropLast()) : raw
      if let colon = s.range(of: ": ") {
        let items = split(String(s[colon.upperBound...]), on: ", ")
        if items.count >= 3 {
          parts.append(.bullets(String(s[..<colon.lowerBound]), items.map(capitalizedFirst)))
          continue
        }
      }
      if let first = s.split(separator: " ").first, verbs.contains(String(first)) {
        parts.append(.action(s))
        continue
      }
      let clauses = split(s, on: "; ")
      if clauses.count >= 2 {
        parts.append(.bullets(nil, clauses.map(capitalizedFirst)))
        continue
      }
      parts.append(.text(capitalizedFirst(s) + "."))
    }
    return parts
  }

  static func readable(_ text: some StringProtocol) -> String {
    var s = String(text).replacingOccurrences(of: "`", with: "")
    for (name, title) in names {
      s = s.replacingOccurrences(of: name, with: title)
    }
    let sha = #"(?=[0-9a-f]*[a-f])(?=[0-9a-f]*[0-9])[0-9a-f]{7,40}"#
    let rules: [(String, String)] = [
      (#"\b(?:window )?\#(sha)\.\.\#(sha)\b"#, "the latest commits"),
      (#"\bsince \#(sha)\b"#, "since its last run"),
      (#" (?:at|on|from|in) \#(sha)\b"#, ""),
      (#"\s?\((?:\#(sha)(?:,\s*)?)+\)"#, ""),
      (#"\b\#(sha)\b"#, "a commit"),
      (#"\s?\(\d{10,}\)"#, ""),
      (#"(?i)\bmerge after act on, (\d+) act on\b"#, "merge once the $1 requested fixes are in"),
      (#"(?i)\bmerge after act on\b"#, "merge once the requested fixes are in"),
      (#"(?i)\b(\d+) act on\b"#, "$1 requested fixes"),
      (#"\bAct on\b"#, "requested fixes"),
      (#"\s?\((?=[^)]*\b[a-z]+[A-Z]\w*)[^)]*\)"#, ""),
      (#"\b(?:[\w.-]+/)+([\w.-]+\.(?:tsx?|jsx?|mjs|md|json|swift|sh|ya?ml|css))\b"#, "$1"),
      (#"^the latest commits\.\s*"#, ""),
      (#" {2,}"#, " "),
      (#" ([,.:;])"#, "$1"),
    ]
    for (pattern, template) in rules {
      s = s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }
    return s
  }

  static func attributed(_ text: String) -> AttributedString {
    var md = ""
    var last = text.startIndex
    for m in text.matches(of: link) {
      md += readable(text[last..<m.range.lowerBound])
      let raw = String(text[m.range])
      let url = trimmed(raw)
      md += "[\(label(url))](\(url))" + raw.dropFirst(url.count)
      last = m.range.upperBound
    }
    md += readable(text[last...])
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    return (try? AttributedString(markdown: md, options: options)) ?? AttributedString(text)
  }

  static func numbers(_ s: String) -> [Int] {
    let re = try! Regex(#"(?:#|/pull/|/issues/)(\d+)\b"#)
    var seen = Set<Int>()
    return s.matches(of: re).compactMap { m in m.output[1].substring.flatMap { Int($0) } }.filter { seen.insert($0).inserted }
  }

  static func sentences(_ s: String) -> [String] {
    var out: [String] = []
    var current = ""
    let chars = Array(s)
    for (i, c) in chars.enumerated() {
      current.append(c)
      let next = i + 2 < chars.count ? chars[i + 2] : nil
      if ".!?".contains(c), i + 1 < chars.count, chars[i + 1] == " ", let next, next.isUppercase || next == "#" {
        out.append(current.trimmingCharacters(in: .whitespaces))
        current = ""
      }
    }
    let rest = current.trimmingCharacters(in: .whitespaces)
    if !rest.isEmpty { out.append(rest) }
    return out
  }

  struct Block {
    let label: String?
    let text: String
    let bullet: Bool
  }

  static func blocks(_ text: String) -> [Block] {
    text.split(separator: "\n").compactMap { raw in
      var line = raw.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty else { return nil }
      var bullet = false
      if line.hasPrefix("- ") {
        bullet = true
        line = String(line.dropFirst(2))
      }
      if let r = line.range(of: ": "), line.distance(from: line.startIndex, to: r.lowerBound) <= 28 {
        let head = line[..<r.lowerBound]
        if head.split(separator: " ").count <= 4, head.first?.isLetter == true, !head.contains("#"), !head.contains("("),
          !head.contains("\"")
        {
          let body = line[r.upperBound...].replacingOccurrences(of: " ; ", with: "\n")
          return Block(label: capitalizedFirst(String(head)), text: body, bullet: false)
        }
      }
      return Block(label: nil, text: line, bullet: bullet)
    }
  }

  static func body(_ b: Brief) -> String {
    let short = LoopSpec.short(b.loop)
    return b.text.hasPrefix("\(short): ") ? String(b.text.dropFirst(short.count + 2)) : b.text
  }

  static func resets(_ limit: String?) -> String? {
    guard let limit else { return nil }
    return Reader.groups(#"(resets [^(]+)"#, in: limit).first?.trimmingCharacters(in: .whitespaces)
  }

  private static func clean(_ s: some StringProtocol) -> String {
    s.trimmingCharacters(in: CharacterSet(charactersIn: " ;:,-\t"))
  }

  private static func afterMarker(_ s: Substring) -> Substring {
    let cut = markers.compactMap { s.range(of: $0, options: .backwards) }.max { $0.upperBound < $1.upperBound }
    return cut.map { s[$0.upperBound...] } ?? s
  }

  static func asks(_ b: Brief) -> [Ask] {
    var out: [Ask] = []
    for raw in b.text.split(separator: "\n") {
      var line = Substring(raw.trimmingCharacters(in: .whitespaces))
      if line.hasPrefix("- ") { line = line.dropFirst(2) }
      let urls = line.ranges(of: cli)
      if urls.isEmpty {
        guard markers.contains(where: { line.contains($0) }) else { continue }
        let text = clean(afterMarker(line))
        guard !text.isEmpty else { continue }
        let url = line.firstMatch(of: link).map { URL(string: trimmed(String(line[$0.range]))) } ?? nil
        out.append(Ask(id: "\(b.loop)|\(text)", loop: b.loop, text: text, url: url, at: b.at))
        continue
      }
      var start = line.startIndex
      for r in urls {
        let text = clean(afterMarker(line[start..<r.lowerBound]))
        if !text.isEmpty {
          out.append(
            Ask(id: "\(b.loop)|\(text)", loop: b.loop, text: text, url: URL(string: trimmed(String(line[r]))), at: b.at))
        }
        start = r.upperBound
      }
    }
    return out
  }
}
