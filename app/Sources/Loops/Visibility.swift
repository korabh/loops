import AppKit
import SwiftUI

extension View {
  func tracksVisibility(of store: Store) -> some View {
    background(VisibilityProbe.Host(store: store))
  }
}

final class VisibilityProbe: NSView {
  private weak var store: Store?
  private(set) var shown = false

  struct Host: NSViewRepresentable {
    let store: Store

    func makeNSView(context: Context) -> VisibilityProbe { VisibilityProbe(store) }

    func updateNSView(_ view: VisibilityProbe, context: Context) { view.attach(store) }
  }

  init(_ store: Store) {
    super.init(frame: .zero)
    attach(store)
  }

  required init?(coder: NSCoder) { nil }

  func attach(_ store: Store) {
    guard store !== self.store else { return }
    self.store = store
    store.track(self)
    update()
  }

  override func viewWillMove(toWindow next: NSWindow?) {
    super.viewWillMove(toWindow: next)
    let center = NotificationCenter.default
    if let window {
      center.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: window)
      center.removeObserver(self, name: NSWindow.willCloseNotification, object: window)
    }
    if let next {
      center.addObserver(self, selector: #selector(changed), name: NSWindow.didChangeOcclusionStateNotification, object: next)
      center.addObserver(self, selector: #selector(closing), name: NSWindow.willCloseNotification, object: next)
    }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    update()
  }

  @objc private func changed(_ note: Notification) { update() }

  @objc private func closing(_ note: Notification) { set(false) }

  private func update() {
    set(window.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false)
  }

  private func set(_ now: Bool) {
    guard now != shown else { return }
    shown = now
    if now { store?.sighted() }
  }
}
