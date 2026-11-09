#if os(macOS)
  import AVFoundation
  import AppKit
  import OmnigentCoreFFI
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentRemoteBrowser

  extension OffscreenWindow {
    /// A popup button's menu, filled as for opening it but not opened.
    fileprivate func popupMenu(at index: Int) throws -> NSMenu {
      let popups = allViews.compactMap { $0 as? NSPopUpButton }
      let menu = try #require(popups[index].menu)
      let willShow = Selector(("popUpButtonCell:willShowMenu:"))
      if let delegate = menu.delegate as? NSObject, delegate.responds(to: willShow) {
        _ = unsafe delegate.perform(willShow, with: popups[index].cell, with: menu)
      }
      return menu
    }

    fileprivate func editableField(at index: Int = 0) throws -> NSTextField {
      let fields = allViews.compactMap { $0 as? NSTextField }.filter(\.isEditable)
      return try #require(fields.indices.contains(index) ? fields[index] : nil)
    }

    /// The custom size sheet's fields, as shown.
    fileprivate var sizeFields: [String] {
      allViews.compactMap { $0 as? NSTextField }.filter(\.isEditable).map(\.stringValue)
    }

    /// Replaces a size field's text and leaves the field, which commits a number field's value.
    fileprivate func enter(_ text: String, inSizeField index: Int) throws {
      try click(try editableField(at: index))
      (activeWindow.firstResponder as? NSText)?.selectAll(nil)
      try type(text)
      try press(keyCode: 48, characters: "\t")
      settle()
    }

    /// Clicks the middle of a frame.
    fileprivate func click(frame: CGRect) throws {
      try click(CGPoint(x: frame.midX, y: frame.midY))
      settle()
    }

    fileprivate func pressReturn() throws { try press(keyCode: 36, characters: "\r") }
    fileprivate func pressEscape() throws { try press(keyCode: 53, characters: "\u{1b}") }
  }

  @MainActor
  @Suite("The remote tab's address field", .serialized)
  struct RemoteAddressFieldTests {
    @Test("Return loads what was typed, as a URL or a search, and leaves the field")
    func submit() async throws {
      let hosted = HostedStore()
      defer { hosted.finish() }
      await hosted.hostSends(HostedStore.snapshot())
      let screen = OffscreenWindow(
        RemoteBrowserToolbar(store: hosted.store), width: 900, height: 60)
      defer { screen.close() }
      screen.settle()
      let field = try screen.editableField()
      #expect(field.stringValue == "https://example.com/")
      try screen.click(field)
      screen.window.firstResponder.map { ($0 as? NSText)?.selectAll(nil) }
      try screen.type("other.example/page")
      try screen.pressReturn()
      screen.settle()
      #expect(hosted.driverCalls.contains("nav navigate https://other.example/page"))
    }

    @Test("Escape puts the page's address back; so does leaving the field")
    func revert() async throws {
      let hosted = HostedStore()
      defer { hosted.finish() }
      await hosted.hostSends(HostedStore.snapshot())
      let screen = OffscreenWindow(
        RemoteBrowserToolbar(store: hosted.store), width: 900, height: 60)
      defer { screen.close() }
      screen.settle()
      let field = try screen.editableField()
      try screen.click(field)
      try screen.type("typed")
      #expect(field.stringValue.contains("typed"))
      try screen.pressEscape()
      screen.settle()
      #expect(try screen.editableField().stringValue == "https://example.com/")
      #expect(!hosted.driverCalls.contains { $0.hasPrefix("nav navigate") })

      try screen.click(field)
      try screen.type("again")
      screen.window.makeFirstResponder(nil)
      screen.settle()
      #expect(try screen.editableField().stringValue == "https://example.com/")
    }
  }

  @MainActor
  @Suite("The remote tab's viewport menu", .serialized)
  struct RemoteViewportMenuTests {
    private func menuScreen(_ hosted: HostedStore) -> OffscreenWindow<RemoteViewportMenu> {
      let screen = OffscreenWindow(RemoteViewportMenu(store: hosted.store), width: 500, height: 400)
      screen.settle()
      return screen
    }

    @Test("Fit, a preset and Keep each set the remote's size")
    func choices() async throws {
      let hosted = HostedStore()
      defer { hosted.finish() }
      await hosted.hostSends(HostedStore.snapshot())
      let screen = menuScreen(hosted)
      defer { screen.close() }
      try screen.choose("Fit to Window", in: try screen.popupMenu(at: 0))
      screen.settle()
      #expect(hosted.store.viewportMode == .fitWindow)
      let preset = RemoteViewportMode.presets[0]
      try screen.choose(preset.label, in: try screen.popupMenu(at: 0))
      screen.settle()
      #expect(hosted.store.viewportMode == .fixed(preset))
      let current = try screen.popupMenu(at: 0)
      #expect(
        current.items.contains { $0.title == "Set Remote Size (\(preset.label))" })
      try screen.choose("Keep Remote Size", in: current)
      screen.settle()
      #expect(hosted.store.viewportMode == .keep)
    }

    @Test("a viewer is told the size only applies while in control")
    func viewerNote() async throws {
      let hosted = HostedStore()
      defer { hosted.finish() }
      await hosted.hostSends(HostedStore.snapshot(connection: .attached(mode: .view)))
      let screen = menuScreen(hosted)
      defer { screen.close() }
      let menu = try screen.popupMenu(at: 0)
      #expect(menu.items.contains { $0.title == "Applies while you are in control" })
    }

    @Test("Custom Size starts from the page's size, refuses a bad size and applies a good one")
    func customSize() async throws {
      let hosted = HostedStore()
      defer { hosted.finish() }
      await hosted.hostSends(HostedStore.snapshot())
      let screen = menuScreen(hosted)
      defer { screen.close() }
      try screen.choose("Custom Size…", in: try screen.popupMenu(at: 0))
      screen.settle(0.3)
      #expect(screen.window.attachedSheet != nil)
      #expect(screen.sizeFields == ["1,000", "500"])

      // A disabled button isn't listed, so find Apply while it's enabled.
      let apply = try #require(screen.controlFrames.last)
      try screen.enter("10", inSizeField: 0)
      #expect(screen.controlFrames.last != apply)
      try screen.click(frame: apply)
      #expect(screen.window.attachedSheet != nil)
      #expect(hosted.store.viewportMode == .keep)

      try screen.enter("1600", inSizeField: 0)
      let toggle = screen.controlFrames[3]
      try screen.click(CGPoint(x: toggle.midX, y: toggle.midY))
      try screen.click(frame: apply)
      screen.settle(0.3)
      #expect(screen.window.attachedSheet == nil)
      #expect(
        hosted.store.viewportMode == .fixed(RemoteViewportSize(width: 1600, height: 500, dpr: 2)))
    }

    @Test("Custom Size starts from a fixed size, or a default, and Cancel changes nothing")
    func customSizeStartsAndCancels() async throws {
      let fixed = RemoteViewportSize(width: 1280, height: 720)
      for (mode, viewport, expected) in [
        (RemoteViewportMode.fixed(fixed), RemoteViewport?.none, ["1,280", "720"]),
        (RemoteViewportMode.keep, RemoteViewport?.none, ["1,280", "800"]),
      ] {
        let hosted = HostedStore(mode: mode)
        defer { hosted.finish() }
        await hosted.hostSends(HostedStore.snapshot(viewport: viewport))
        let screen = menuScreen(hosted)
        defer { screen.close() }
        try screen.choose("Custom Size…", in: try screen.popupMenu(at: 0))
        screen.settle(0.3)
        #expect(screen.sizeFields == expected)
        let cancel = try #require(screen.controlFrames.dropLast().last)
        try screen.click(frame: cancel)
        screen.settle(0.3)
        #expect(screen.window.attachedSheet == nil)
        #expect(hosted.store.viewportMode == mode)
      }
    }
  }

  @MainActor
  @Suite("A pointer crossing the remote page", .serialized)
  struct RemotePointerCrossingTests {
    @Test("entering and leaving the page reach the host; the letterbox doesn't")
    func crossing() async throws {
      let (hosted, view) = await inControl()
      defer { hosted.finish() }
      let inside = try #require(
        NSEvent.mouseEvent(
          with: .mouseMoved, location: CGPoint(x: 500, y: 500), modifierFlags: [], timestamp: 0,
          windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
      view.mouseEntered(with: inside)
      #expect(hosted.connector.driver.mice.count == 1)
      let letterbox = try #require(
        NSEvent.mouseEvent(
          with: .mouseMoved, location: CGPoint(x: 500, y: 100), modifierFlags: [], timestamp: 0,
          windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
      view.mouseExited(with: letterbox)
      #expect(hosted.connector.driver.mice.map(\.kind) == [.move, .leave])
    }
  }

  @MainActor
  @Suite("Small remote view details")
  struct RemoteViewDetailTests {
    @Test("a view with no decoded picture has no edge color to sample")
    func noPicture() {
      #expect(RemoteVideoRenderer().sampleTopEdge() == nil)
    }

    @Test("a healthy decoder's notification doesn't ask the host for a keyframe")
    func healthyDecoderNotification() async throws {
      let renderer = RemoteVideoRenderer()
      var requests = 0
      renderer.requestKeyframe = { _ in requests += 1 }
      NotificationCenter.default.post(
        name: AVSampleBufferVideoRenderer.didFailToDecodeNotification,
        object: renderer.layer.sampleBufferRenderer)
      await letTasksRun()
      #expect(requests == 0)
      #expect(renderer.lastError == nil)
    }

    @Test("detaching while the host is still connecting ends quietly; a hidden tab keeps its state")
    func stoppedWhileConnecting() async throws {
      let host = FixtureRemoteBrowser(latency: .seconds(30))
      host.addTab(id: "t", url: "https://example.com/")
      let store = RemoteBrowserStore(sessionID: "s", tabID: "t")
      store.attach(using: host, mode: .view, hostID: nil)
      await letTasksRun()
      #expect(!store.canSendInput)
      store.detach()
      await letTasksRun()
      #expect(store.fixtureDriver == nil)

      let quick = FixtureRemoteBrowser(latency: .milliseconds(1))
      quick.addTab(id: "t", url: "https://example.com/")
      let hidden = RemoteBrowserStore(sessionID: "s", tabID: "t")
      hidden.pasteboard = MemoryPasteboard()
      hidden.attach(using: quick, mode: .control, hostID: nil)
      #expect(try await eventually(seconds: 5) { hidden.canSendInput })
      hidden.setVisible(false)
      try await Task.sleep(for: .milliseconds(80))
      #expect(hidden.canSendInput)
      hidden.detach()
    }

    @Test("the app's tab overview button is accepted by the view")
    func tabsButton() async {
      let hosted = HostedStore()
      defer { hosted.finish() }
      let page = OffscreenPage {
        RemoteBrowserTabView(store: hosted.store) { Text("Tabs") }
      }
      defer { page.close() }
      #expect(await page.draw() > 0)
    }

    @Test("a stopped scroll on one axis keeps the other's momentum")
    func stopOneAxis() {
      var keepsSideways = RemoteMomentum(velocity: CGPoint(x: 3000, y: 3000))
      keepsSideways.stop(vertical: true)
      let sideways = keepsSideways.step(1.0 / 60)
      #expect(sideways.x > 0)
      #expect(sideways.y == 0)
      var keepsVertical = RemoteMomentum(velocity: CGPoint(x: 3000, y: 3000))
      keepsVertical.stop(vertical: false)
      let vertical = keepsVertical.step(1.0 / 60)
      #expect(vertical.x == 0)
      #expect(vertical.y > 0)
    }
  }
#endif
