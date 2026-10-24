import Foundation
import Network

struct HookEvent: @unchecked Sendable {
  let name: String
  let session: String
  let cwd: String?
  let agent: String?
  let tool: String?
  let input: [String: Any]
  let at: Date

  init?(_ body: Data, at: Date) {
    guard let o = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
      let name = o["hook_event_name"] as? String, let session = o["session_id"] as? String
    else { return nil }
    self.name = name
    self.session = session
    cwd = o["cwd"] as? String
    agent = o["agent_id"] as? String
    tool = o["tool_name"] as? String
    input = o["tool_input"] as? [String: Any] ?? [:]
    self.at = at
  }
}

final class HookServer: @unchecked Sendable {
  static let port: UInt16 = 47_823
  private static let limit = 16 << 20
  private static let ok = Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n".utf8)
  private static let missing = Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n".utf8)

  private let queue = DispatchQueue(label: "io.github.korabh.loops.hooks", qos: .userInitiated)
  private let path: String
  private let deliver: @Sendable (HookEvent) -> Void
  private var listener: NWListener?

  init(token: String, deliver: @escaping @Sendable (HookEvent) -> Void) {
    path = "/hook/\(token)"
    self.deliver = deliver
  }

  var url: String { "http://127.0.0.1:\(Self.port)\(path)" }

  func start() {
    guard listener == nil, let port = NWEndpoint.Port(rawValue: Self.port) else { return }
    let params = NWParameters.tcp
    params.acceptLocalOnly = true
    params.allowLocalEndpointReuse = true
    params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
    guard let listener = try? NWListener(using: params) else { return }
    listener.newConnectionHandler = { [weak self] connection in
      guard let self else { return connection.cancel() }
      connection.start(queue: self.queue)
      self.serve(connection, Data())
    }
    listener.start(queue: queue)
    self.listener = listener
  }

  private func serve(_ connection: NWConnection, _ pending: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
      guard let self else { return connection.cancel() }
      var pending = pending
      if let data { pending.append(data) }
      while let request = Self.request(&pending) {
        let ours = request.target == self.path
        let event = ours ? HookEvent(request.body, at: Date()) : nil
        connection.send(content: ours ? Self.ok : Self.missing, completion: .contentProcessed { _ in })
        if let event { self.deliver(event) }
      }
      if done || error != nil || pending.count > Self.limit { connection.cancel() } else { self.serve(connection, pending) }
    }
  }

  static func request(_ pending: inout Data) -> (target: String, body: Data)? {
    guard let split = pending.range(of: Data("\r\n\r\n".utf8)) else { return nil }
    let head = String(decoding: pending[pending.startIndex..<split.lowerBound], as: UTF8.self).split(separator: "\r\n")
    let target = head.first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
    let length =
      head.dropFirst().lazy.compactMap { line -> Int? in
        let pair = line.split(separator: ":", maxSplits: 1)
        guard pair.count == 2, pair[0].lowercased() == "content-length" else { return nil }
        return Int(pair[1].trimmingCharacters(in: .whitespaces))
      }.first ?? 0
    guard pending.distance(from: split.upperBound, to: pending.endIndex) >= length else { return nil }
    let end = pending.index(split.upperBound, offsetBy: length)
    let body = pending.subdata(in: split.upperBound..<end)
    pending = pending.subdata(in: end..<pending.endIndex)
    return (target, body)
  }
}

enum Lifecycle {
  static let events = ["PreToolUse", "SubagentStart", "SubagentStop", "Stop", "StopFailure", "Notification", "SessionEnd"]

  static func settings(url: String) -> Data {
    let hook: [String: Any] = ["type": "http", "url": url, "timeout": 2]
    let hooks = Dictionary(uniqueKeysWithValues: events.map { ($0, [["hooks": [hook]]]) })
    return (try? JSONSerialization.data(withJSONObject: ["hooks": hooks], options: [.prettyPrinted, .sortedKeys])) ?? Data()
  }

  static func reporter(of file: String, in projects: [String]) -> String? {
    guard let root = projects.first(where: { file.hasPrefix($0 + "/") }) else { return nil }
    let parts = file.dropFirst(root.count + 1).split(separator: "/")
    guard let name = parts.last, name.hasSuffix(".jsonl") else { return "" }
    if parts.count == 1 { return String(name.dropLast(6)) }
    return name.hasPrefix("agent-") ? String(name.dropFirst(6).dropLast(6)) : ""
  }
}

extension Store {
  var hookSettings: URL { paths.common.appending(path: "loop-hooks.json") }

  var hookArgs: [String] {
    FileManager.default.fileExists(atPath: hookSettings.path) ? ["--settings", hookSettings.path] : []
  }

  func listen() {
    let defaults = UserDefaults.standard
    let token = defaults.string(forKey: "hookToken") ?? UUID().uuidString.lowercased()
    defaults.set(token, forKey: "hookToken")
    let server = HookServer(token: token) { [weak self] event in
      DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(event) } }
    }
    server.start()
    hooks = server
    let data = Lifecycle.settings(url: server.url)
    guard FileManager.default.contents(atPath: hookSettings.path) != data else { return }
    if (try? data.write(to: hookSettings, options: .atomic)) != nil {
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: hookSettings.path)
    }
  }

  func receive(_ e: HookEvent) {
    hooked.insert(e.agent ?? e.session)
    let job = jobs.jobs.values.first { $0.sessionId == e.session }
    let runner = fromRunner(e)
    switch e.name {
    case "PreToolUse":
      guard let tool = e.tool else { return }
      if let job { jobs.record(tool, e.input, for: job.id) }
      advance(e, tool, runner: runner)
    case "SubagentStart":
      if runner { liveLater(0.3) }
    case "SubagentStop":
      if runner { liveLater(0.3) }
      spendLater()
    default:
      if job != nil {
        Task {
          await jobs.reconcile()
          refreshTasks()
        }
      }
      if runner {
        liveLater(0.3)
        Task { await refreshRunner() }
      }
      if e.name != "Notification" { spendLater() }
    }
  }

  private func fromRunner(_ e: HookEvent) -> Bool {
    if let id = runner?.session?.id, !id.isEmpty, e.session.hasPrefix(id) { return true }
    return e.cwd == paths.runner.path
  }

  private func advance(_ e: HookEvent, _ tool: String, runner: Bool) {
    let key = e.agent ?? "\(e.session).jsonl"
    guard let live, let i = live.agents.firstIndex(where: { $0.id == key }) else {
      if runner, e.agent != nil { liveLater(0.3) }
      return
    }
    var agents = live.agents
    agents[i] = agents[i].advanced(Live.describe(["name": tool, "input": e.input]), at: e.at)
    self.live = LiveTick(id: live.id, started: live.started, agents: agents)
  }
}
