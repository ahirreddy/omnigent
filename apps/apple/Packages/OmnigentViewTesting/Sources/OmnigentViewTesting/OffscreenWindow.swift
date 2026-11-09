#if os(macOS)
  public import AppKit
  public import SwiftUI

  /// A failure to drive an offscreen window.
  public enum OffscreenWindowError: Error, Equatable, CustomStringConvertible {
    /// AppKit declined to make an event.
    case eventUnavailable
    /// No view or menu item has this name.
    case notFound(String)

    /// A sentence saying what failed.
    public var description: String {
      switch self {
      case .eventUnavailable: "AppKit could not create the event."
      case .notFound(let name): "Nothing is named \(name)."
      }
    }
  }

  /// A window that believes it is key without ever taking the keyboard or activating the app.
  private final class AlwaysKeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
  }

  /// Hosts a SwiftUI view off every display and drives it with real AppKit events, so a test runs
  /// the same hit testing, focus and key handling as the app without a UI test.
  ///
  /// Clicks reach `Button`s of any style, `Toggle`s, text fields and menus. They don't reach
  /// `onTapGesture` or `onHover`: cover those through the action the view was given.
  @MainActor
  public final class OffscreenWindow<Content: View> {
    /// Far past any display, so the window is never seen and takes no real clicks.
    private static var origin: CGPoint { CGPoint(x: -20_000, y: -20_000) }

    /// The window holding the view.
    public let window: NSWindow
    /// The hosting view; click coordinates are in its flipped space, from the top left.
    public let host: NSHostingView<Content>

    /// Puts the view on its window and lays it out.
    /// - Parameters:
    ///   - view: The view under test.
    ///   - width: The window's width.
    ///   - height: The window's height.
    public init(_ view: Content, width: CGFloat = 800, height: CGFloat = 600) {
      SystemSideEffects.install()
      let app = NSApplication.shared
      if app.activationPolicy() != .accessory {
        // AppKit would otherwise end the test process when its last window goes away.
        ProcessInfo.processInfo.disableAutomaticTermination("Offscreen window tests")
        ProcessInfo.processInfo.disableSuddenTermination()
        app.setActivationPolicy(.accessory)
      }
      host = NSHostingView(rootView: view)
      window = AlwaysKeyWindow(
        contentRect: CGRect(origin: Self.origin, size: CGSize(width: width, height: height)),
        styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = host
      window.orderFrontRegardless()
      settle()
    }

    /// Removes the view from its window. Later events do nothing.
    public func close() {
      window.orderOut(nil)
      window.contentView = nil
      // AppKit queues run loop stops while windows change. Left for the test runner's own loop,
      // one would end the process early with exit code 0: a false pass.
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }

    /// Runs the main run loop, so state changes, tasks and animations proceed.
    /// - Parameter seconds: How long to run.
    public func settle(_ seconds: TimeInterval = 0.1) {
      host.layoutSubtreeIfNeeded()
      RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
      host.layoutSubtreeIfNeeded()
    }

    /// Clicks a point with a real mouse down and up.
    /// - Parameters:
    ///   - point: The point, from the top left of the view.
    ///   - clickCount: How many clicks the event reports.
    ///   - modifiers: Keys held during the click.
    /// - Throws: `OffscreenWindowError` when AppKit declines an event.
    public func click(
      _ point: CGPoint, clickCount: Int = 1, modifiers: NSEvent.ModifierFlags = []
    ) throws {
      let down = try mouseEvent(.leftMouseDown, point, clickCount, modifiers)
      let mouseUp = try mouseEvent(.leftMouseUp, point, clickCount, modifiers, delay: 0.03)
      // An AppKit control tracks the mouse inside its mouse down until it sees the up. Posting
      // stops the run loop in progress, so post only from inside that tracking: stopping the test
      // runner's own loop would end the process with a false pass.
      nonisolated(unsafe) let trackedUp = mouseUp
      let release = Timer(timeInterval: 0.03, repeats: false) { _ in
        MainActor.assumeIsolated { NSApp.postEvent(unsafe trackedUp, atStart: false) }
      }
      RunLoop.main.add(release, forMode: .common)
      window.sendEvent(down)
      if release.isValid {
        release.invalidate()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
        window.sendEvent(mouseUp)
      }
      settle()
    }

    /// Clicks the middle of a view found in the window.
    /// - Parameter view: A view in this window.
    /// - Throws: `OffscreenWindowError` when AppKit declines an event.
    public func click(_ view: NSView) throws {
      let frame = view.convert(view.bounds, to: host)
      try click(CGPoint(x: frame.midX, y: frame.midY))
    }

    /// Sends text as key presses to whatever has focus.
    /// - Parameter text: The characters to type.
    /// - Throws: `OffscreenWindowError` when AppKit declines an event.
    public func type(_ text: String) throws {
      for character in text {
        let characters = String(character)
        try press(keyCode: 0, characters: characters)
      }
    }

    /// Presses one key.
    /// - Parameters:
    ///   - keyCode: The virtual key code, such as 36 for Return and 53 for Escape.
    ///   - characters: The characters the key makes.
    ///   - modifiers: Keys held with it.
    /// - Throws: `OffscreenWindowError` when AppKit declines an event.
    public func press(
      keyCode: UInt16, characters: String = "", modifiers: NSEvent.ModifierFlags = []
    ) throws {
      for type in [NSEvent.EventType.keyDown, .keyUp] {
        let event = NSEvent.keyEvent(
          with: type, location: .zero, modifierFlags: modifiers,
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
          context: nil, characters: characters, charactersIgnoringModifiers: characters,
          isARepeat: false, keyCode: keyCode)
        guard let event else { throw OffscreenWindowError.eventUnavailable }
        window.sendEvent(event)
      }
      settle(0.02)
    }

    /// Every view under the window's content, in depth-first order.
    public var allViews: [NSView] {
      var found: [NSView] = []
      var pending: [NSView] = [host]
      while let view = pending.popLast() {
        found.append(view)
        pending.append(contentsOf: view.subviews.reversed())
      }
      return found
    }

    /// The frames of the controls that take focus, from the top left and in layout order: every
    /// button of any style, toggle, menu and field. SwiftUI keeps one proxy view for each.
    public var controlFrames: [CGRect] {
      let proxies = allViews.filter { String(describing: Swift.type(of: $0)) == "KeyViewProxy" }
      return proxies.map { $0.convert($0.bounds, to: host) }
    }

    /// Clicks the middle of a control by its position in `controlFrames`.
    /// - Parameter index: The control's position.
    /// - Throws: `OffscreenWindowError` when no control has that position.
    public func clickControl(at index: Int) throws {
      let frames = controlFrames
      guard frames.indices.contains(index) else {
        throw OffscreenWindowError.notFound("control \(index) of \(frames.count)")
      }
      try click(CGPoint(x: frames[index].midX, y: frames[index].midY))
    }

    /// Clicks a point that opens a `Menu`, and returns the menu after closing it at once.
    /// - Parameter point: The point, from the top left of the view.
    /// - Returns: The menu; pass it to `choose(_:in:)` to run an item.
    /// - Throws: `OffscreenWindowError` when the click opened no menu.
    public func openMenu(_ point: CGPoint) throws -> NSMenu {
      nonisolated(unsafe) var opened: NSMenu?
      let center = NotificationCenter.default
      let observer = center.addObserver(
        forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil
      ) { note in
        let menu = note.object as? NSMenu
        unsafe opened = menu
        // Canceling before the tracking loop starts would be lost.
        let close = Timer(timeInterval: 0.05, repeats: false) { _ in
          menu?.cancelTrackingWithoutAnimation()
        }
        RunLoop.main.add(close, forMode: .common)
      }
      defer { center.removeObserver(observer) }
      try click(point)
      guard let menu = unsafe opened else { throw OffscreenWindowError.notFound("a menu") }
      return menu
    }

    /// The menu a right click at a point would open, without opening it.
    /// - Parameter point: The point, from the top left of the view.
    /// - Returns: The context menu, or `nil` when the point has none.
    /// - Throws: `OffscreenWindowError` when AppKit declines the event.
    public func contextMenu(at point: CGPoint) throws -> NSMenu? {
      let event = try mouseEvent(.rightMouseDown, point, 1, [])
      let target = unsafe host.hitTest(host.convert(point, to: host.superview)) ?? host
      return target.menu(for: event)
    }

    /// Runs a menu item's action, as choosing it does.
    /// - Parameters:
    ///   - title: The item's title, at any depth.
    ///   - menu: The menu to search.
    /// - Throws: `OffscreenWindowError` when no item has that title.
    public func choose(_ title: String, in menu: NSMenu) throws {
      guard let (owner, index) = Self.item(titled: title, in: menu) else {
        throw OffscreenWindowError.notFound(title)
      }
      owner.performActionForItem(at: index)
      settle()
    }

    private static func item(titled title: String, in menu: NSMenu) -> (NSMenu, Int)? {
      for (index, item) in menu.items.enumerated() {
        if item.title == title { return (menu, index) }
        if let submenu = item.submenu, let found = self.item(titled: title, in: submenu) {
          return found
        }
      }
      return nil
    }

    private func mouseEvent(
      _ type: NSEvent.EventType, _ point: CGPoint, _ clickCount: Int,
      _ modifiers: NSEvent.ModifierFlags, delay: TimeInterval = 0
    ) throws -> NSEvent {
      let event = NSEvent.mouseEvent(
        with: type, location: host.convert(point, to: nil), modifierFlags: modifiers,
        timestamp: ProcessInfo.processInfo.systemUptime + delay,
        windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: clickCount,
        pressure: 1)
      guard let event else { throw OffscreenWindowError.eventUnavailable }
      return event
    }
  }
#endif
