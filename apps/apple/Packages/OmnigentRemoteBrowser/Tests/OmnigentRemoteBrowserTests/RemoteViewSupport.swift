#if os(macOS)
  import AppKit
  import Foundation
  import OmnigentCoreFFI
  import SwiftUI
  import Testing

  @testable import OmnigentRemoteBrowser

  /// A store attached to a recording driver, so a test speaks as the host. The pasteboard is kept
  /// off the system's, and a saved viewport mode doesn't outlive the test.
  @MainActor
  struct HostedStore {
    let connector = RecordingConnector()
    let store: RemoteBrowserStore

    init(lastURL: String = "", mode: RemoteViewportMode = .keep) {
      UserDefaults.standard.removeObject(forKey: RemoteViewportModeDefaults.key)
      store = RemoteBrowserStore(sessionID: "s", tabID: "t", lastURL: lastURL)
      store.pasteboard = MemoryPasteboard()
      store.attach(using: connector, mode: .control, hostID: nil)
      store.viewportMode = mode
    }

    var driverCalls: [String] { connector.driver.log }

    /// Forgets the saved mode; call when the test ends.
    func finish() {
      store.detach()
      UserDefaults.standard.removeObject(forKey: RemoteViewportModeDefaults.key)
    }

    /// A snapshot in control of the page, unless the arguments say otherwise.
    static func snapshot(
      connection: RemoteBrowserConnection = .attached(mode: .control),
      owner: ControlOwner = .user, holder: ControlHolder = .this,
      viewport: RemoteViewport? = RemoteViewport(width: 1000, height: 500, dpr: 1),
      edit: Bool = true
    ) -> RemoteBrowserSnapshot {
      var snapshot = RemoteBrowserSnapshot.initial(url: "https://example.com/", profile: "work")
      snapshot.connection = connection
      snapshot.control = RemoteBrowserControl(
        owner: owner, holder: holder, userId: nil, handoff: nil)
      snapshot.viewport = viewport
      snapshot.capabilities.edit = edit
      return snapshot
    }

    /// Delivers a snapshot and lets the store and any view observing it take it in.
    func hostSends(_ snapshot: RemoteBrowserSnapshot) async {
      connector.listener?.onState(snapshot: snapshot)
      await letTasksRun()
    }
  }

  /// A store in control with a view in no window; 1000 x 1000 points showing a page 1000 x 500,
  /// so the page is y 250 to 750 and the rest is letterbox.
  @MainActor
  func inControl(
    _ snapshot: RemoteBrowserSnapshot = HostedStore.snapshot()
  ) async -> (HostedStore, RemoteBrowserView) {
    let hosted = HostedStore()
    let view = RemoteBrowserView(store: hosted.store)
    view.frame = CGRect(x: 0, y: 0, width: 1000, height: 1000)
    await hosted.hostSends(snapshot)
    return (hosted, view)
  }

  /// Lets queued main-actor work run; `Task.sleep` is slow at background priority.
  @MainActor
  func letTasksRun() async {
    for _ in 0..<40 { await Task.yield() }
  }

  /// A window that is never ordered in, far from the pointer, so a view in it can't change the
  /// cursor on the user's screen.
  @MainActor
  func neverShownWindow(size: CGSize) -> NSWindow {
    _ = NSApplication.shared
    let window = NSWindow(
      contentRect: CGRect(origin: CGPoint(x: -60_000, y: -60_000), size: size),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    return window
  }

  /// A SwiftUI view in a never-shown window, drawn and pressed without any pointer.
  @MainActor
  final class OffscreenPage<Content: View> {
    let host: NSHostingView<AnyView>
    let window: NSWindow

    init(width: CGFloat = 900, height: CGFloat = 600, @ViewBuilder content: () -> Content) {
      let size = CGSize(width: width, height: height)
      window = neverShownWindow(size: size)
      host = NSHostingView(rootView: AnyView(content().frame(width: width, height: height)))
      window.contentView = host
      host.frame = CGRect(origin: .zero, size: size)
    }

    /// Applies pending updates: a hidden window has no display cycle, so drawing does it.
    @discardableResult
    func draw() async -> Int {
      var pixels = 0
      for _ in 0..<3 {
        host.layoutSubtreeIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
          host.cacheDisplay(in: host.bounds, to: bitmap)
          pixels = bitmap.pixelsWide * bitmap.pixelsHigh
        }
        await letTasksRun()
      }
      return pixels
    }

    /// The buttons AppKit draws, in order: the borderless style's, and never a popup button,
    /// whose click would open its menu.
    var buttons: [NSButton] {
      descendants(of: host, as: NSButton.self).filter { !($0 is NSPopUpButton) }
    }

    /// The text fields on the page, in order.
    var textFields: [NSTextField] {
      descendants(of: host, as: NSTextField.self).filter { $0.isEditable }
    }

    /// The titles of the page's popup menus; they are never opened.
    var popupTitles: [String] {
      descendants(of: host, as: NSPopUpButton.self).map(\.title)
    }

    private func descendants<Found: NSView>(of view: NSView, as type: Found.Type) -> [Found] {
      view.subviews.flatMap { subview in
        (subview as? Found).map { [$0] }.map { $0 + descendants(of: subview, as: type) }
          ?? descendants(of: subview, as: type)
      }
    }

    func close() {
      window.contentView = nil
    }
  }
#endif
