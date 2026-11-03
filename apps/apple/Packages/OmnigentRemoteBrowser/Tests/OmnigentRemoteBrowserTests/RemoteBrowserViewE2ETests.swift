#if os(macOS)
  import AppKit
  import OmnigentCoreFFI
  import Testing

  @testable import OmnigentRemoteBrowser

  /// macOS input end to end without UI automation: AppKit events delivered to a
  /// ``RemoteBrowserView`` in a window that is never shown, through the view, the store and the
  /// core's driver, to the fixture page on a live host. The page reports what it received in
  /// its title (`apps/apple/Tests/Fixtures/remote-browser/index.html`). Nothing moves the
  /// pointer or takes the keyboard, so it runs beside other work.
  ///
  /// Same environment as ``RemoteBrowserE2ETests``; skipped without it.
  @MainActor
  @Suite("Remote browser view end to end", .enabled(if: LiveHost.current != nil), .serialized)
  struct RemoteBrowserViewE2ETests {
    @Test func appKitEventsReachThePageOnlyWhileInControl() async throws {
      let live = try #require(LiveHost.current)
      let core = try RemoteBrowserE2ETests.core()
      defer { core.shutdown() }
      let phase = try await core.connect(serverUrl: live.server, expectedUserId: nil)
      guard case .connected = phase else { throw E2EError("not connected: \(phase)") }
      let connector = CoreRemoteBrowserConnector(core: core)
      let tab = try await connector.createTab(
        sessionID: live.sessionID, url: live.page, profile: nil)

      let store = RemoteBrowserStore(sessionID: live.sessionID, tabID: tab.id)
      let surface = HiddenSurface(store: store)
      store.attach(using: connector, mode: .control, hostID: nil)
      defer { store.detach() }
      #expect(
        try await eventually(seconds: 30) { store.navigation.title == "RB test page" },
        "the page did not load: \(store.navigation.title)")
      store.takeControl()
      #expect(try await eventually(seconds: 10) { store.canSendInput }, "control was not taken")

      // Click the field, type, then click the button.
      try surface.click(css: CGPoint(x: 300, y: 70))
      try surface.type("hello", keyCodes: [4, 14, 37, 37, 31])
      #expect(
        try await eventually(seconds: 10) { store.navigation.title.hasSuffix("typed:hello") },
        "typing did not reach the page: \(store.navigation.title)")
      try surface.click(css: CGPoint(x: 700, y: 70))
      #expect(
        try await eventually(seconds: 10) { store.navigation.title.hasSuffix("clicked:1") },
        "the click did not reach the page: \(store.navigation.title)")

      // A wheel over the list scrolls it.
      try surface.scroll(css: CGPoint(x: 400, y: 500), pixels: -400)
      #expect(
        try await eventually(seconds: 10) { store.navigation.title.contains("scrolled:") },
        "the scroll did not reach the page: \(store.navigation.title)")

      // Handed back, clicks stay here; taken again, they reach the page.
      store.releaseControl()
      #expect(try await eventually(seconds: 10) { !store.canSendInput }, "control stayed here")
      try surface.click(css: CGPoint(x: 700, y: 70))
      try await Task.sleep(for: .seconds(1))
      #expect(
        !store.navigation.title.hasSuffix("clicked:2"), "a click reached the page after Hand Back")
      store.takeControl()
      #expect(try await eventually(seconds: 10) { store.canSendInput }, "control was not retaken")
      try surface.click(css: CGPoint(x: 700, y: 70))
      #expect(
        try await eventually(seconds: 10) { store.navigation.title.hasSuffix("clicked:2") },
        "a click after Take Over did not reach the page: \(store.navigation.title)")

      store.detach()
      try await connector.closeTab(sessionID: live.sessionID, tabID: tab.id)
    }
  }

  /// A borderless window, never ordered on screen, holding a remote view at the host's default
  /// viewport size so CSS pixels are view points. Events go straight to the view's handlers:
  /// AppKit routes no mouse events to a window that was never shown in an inactive app, and
  /// the window server is not involved, so the real pointer and keyboard are untouched.
  @MainActor
  private final class HiddenSurface {
    private static let viewport = CGSize(width: 1280, height: 800)
    let window: KeyableWindow
    let view: RemoteBrowserView

    init(store: RemoteBrowserStore) {
      view = RemoteBrowserView(store: store)
      window = KeyableWindow(
        contentRect: CGRect(origin: .zero, size: Self.viewport), styleMask: [.borderless],
        backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      view.frame = CGRect(origin: .zero, size: Self.viewport)
      window.contentView = view
      window.layoutIfNeeded()
    }

    /// Mouse down and up at a CSS point of the page.
    func click(css point: CGPoint) throws {
      let location = view.convert(point, to: nil)
      for (type, pressure) in [(NSEvent.EventType.leftMouseDown, 1.0), (.leftMouseUp, 0.0)] {
        guard
          let event = NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: [], timestamp: Self.now,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
            pressure: Float(pressure))
        else { throw E2EError("could not create a \(type) event") }
        if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
      }
    }

    /// Key down and up for each character; `keyCodes` are the Mac virtual key codes.
    func type(_ text: String, keyCodes: [UInt16]) throws {
      for (character, code) in zip(text, keyCodes) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
          guard
            let event = NSEvent.keyEvent(
              with: type, location: .zero, modifierFlags: [], timestamp: Self.now,
              windowNumber: window.windowNumber, context: nil, characters: String(character),
              charactersIgnoringModifiers: String(character), isARepeat: false, keyCode: code)
          else { throw E2EError("could not create a \(type) event for \(character)") }
          if type == .keyDown { view.keyDown(with: event) } else { view.keyUp(with: event) }
        }
      }
    }

    /// A precise (trackpad-style) wheel event at a CSS point; negative `pixels` scrolls down.
    func scroll(css point: CGPoint, pixels: Int32) throws {
      // A scroll event carries a screen location; the window sits at the screen origin, so the
      // location in the window is the AppKit screen point.
      let inWindow = view.convert(point, to: nil)
      let screenHeight = NSScreen.screens.first?.frame.height ?? Self.viewport.height
      guard
        let cgEvent = CGEvent(
          scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: pixels, wheel2: 0,
          wheel3: 0)
      else { throw E2EError("could not create a scroll event") }
      cgEvent.location = CGPoint(x: inWindow.x, y: screenHeight - inWindow.y)
      guard let event = NSEvent(cgEvent: cgEvent) else {
        throw E2EError("could not convert the scroll event")
      }
      view.scrollWheel(with: event)
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
  }

  /// Can be key without being shown, so key events reach its first responder.
  private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
  }
#endif
