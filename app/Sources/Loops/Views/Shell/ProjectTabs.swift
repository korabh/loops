import AppKit
import SwiftUI

@MainActor
enum ProjectTabs {
  static weak var host: NSWindow?
  static var joinUntil = Date.distantPast

  static func joinNext() { joinUntil = Date().addingTimeInterval(1) }

  static func host(besides window: NSWindow) -> NSWindow? {
    if let host, host !== window, host.isVisible { return host }
    return NSApp.windows.first { $0 !== window && $0.isVisible && $0.tabbingIdentifier == "project" }
  }
}

struct ProjectTabbing: NSViewRepresentable {
  let becameKey: () -> Void

  func makeNSView(context: Context) -> Probe { Probe(becameKey: becameKey) }
  func updateNSView(_ probe: Probe, context: Context) { probe.becameKey = becameKey }

  final class Probe: NSView {
    var becameKey: () -> Void
    private var observer: NSObjectProtocol?

    init(becameKey: @escaping () -> Void) {
      self.becameKey = becameKey
      super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let observer { NotificationCenter.default.removeObserver(observer) }
      observer = nil
      guard let window else { return }
      window.tabbingIdentifier = "project"
      window.tabbingMode = .preferred
      if Date() < ProjectTabs.joinUntil, window.tabbedWindows == nil, let host = ProjectTabs.host(besides: window) {
        (host.tabGroup?.windows.last ?? host).addTabbedWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil)
      }
      ProjectTabs.joinUntil = .distantPast
      observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) {
        [weak self] note in
        MainActor.assumeIsolated {
          ProjectTabs.host = note.object as? NSWindow
          self?.becameKey()
        }
      }
    }
  }
}
