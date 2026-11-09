#if os(macOS)
  import AppKit
  import Foundation
  import OmnigentCoreFFI
  import SwiftUI
  import Testing

  @testable import OmnigentRemoteBrowser

  /// What a host could put in a field the chrome shows.
  nonisolated private let oddStrings = [
    "", " ", "\u{0}", String(repeating: "W", count: 20_000), "\u{202E}gnp.exe",
    String(repeating: "e\u{301}\u{302}\u{303}", count: 500), "\n\n\n", "😀👨‍👩‍👧‍👦", "\u{FFFF}",
  ]

  @MainActor
  @Suite("Remote tab rendered offscreen", .serialized)
  struct RemoteBrowserTabRenderTests {
    nonisolated private static let error = CoreError.RemoteBrowser(
      kind: .invalidUrl, message: "Bad \u{0}", requiresSignIn: false)

    nonisolated private static let connections: [RemoteBrowserConnection] = [
      .idle, .connecting, .attached(mode: .control), .attached(mode: .view), .stopped,
      .reconnecting(reason: error, failures: .max, delayMs: .max),
      .reconnecting(reason: error, failures: 0, delayMs: 0),
      .failed(failure: .wrongReplica, message: "", requiresSignIn: true),
      .failed(
        failure: .wrongReplica, message: String(repeating: "x", count: 20_000),
        requiresSignIn: false),
      .closed(reason: .tabEnded(reason: .crashed, detail: "\u{0}")),
      .closed(reason: .tabEnded(reason: nil, detail: "")),
      .closed(reason: .serverClosed(code: .max, reason: "")),
    ]

    @Test("every connection state draws over the page", arguments: connections)
    func everyConnection(connection: RemoteBrowserConnection) async {
      let hosted = HostedStore(lastURL: "https://example.com/")
      defer { hosted.finish() }
      await hosted.hostSends(HostedStore.snapshot(connection: connection))
      let page = OffscreenPage { RemoteBrowserTabView(store: hosted.store) { _ in } }
      defer { page.close() }
      #expect(await page.draw() > 0)
      #expect(hosted.store.renderer != nil)
    }

    @Test("the toolbar's buttons follow the page and send navigation")
    func toolbarButtons() async throws {
      let hosted = HostedStore()
      defer { hosted.finish() }
      var snapshot = HostedStore.snapshot()
      snapshot.nav?.canGoBack = true
      snapshot.nav?.canGoForward = true
      await hosted.hostSends(snapshot)
      let page = OffscreenPage { RemoteBrowserToolbar(store: hosted.store) }
      defer { page.close() }
      await page.draw()
      let buttons = page.buttons
      try #require(buttons.count == 3)
      #expect(buttons.allSatisfy { $0.isEnabled })
      for button in buttons { button.performClick(nil) }
      #expect(
        hosted.driverCalls.filter { $0.hasPrefix("nav") } == [
          "nav back ", "nav forward ", "nav reload ",
        ])
    }

    @Test("a loading page offers stop, and a page with no history no way back")
    func loadingPage() async throws {
      let hosted = HostedStore()
      defer { hosted.finish() }
      var snapshot = HostedStore.snapshot()
      snapshot.nav?.loading = true
      await hosted.hostSends(snapshot)
      let page = OffscreenPage { RemoteBrowserToolbar(store: hosted.store) }
      defer { page.close() }
      await page.draw()
      let buttons = page.buttons
      try #require(buttons.count == 3)
      #expect(!buttons[0].isEnabled)
      #expect(!buttons[1].isEnabled)
      buttons[2].performClick(nil)
      #expect(hosted.driverCalls.last == "nav stop ")
    }

    @Test("an ended tab turns off everything but its text")
    func endedTab() async throws {
      let hosted = HostedStore()
      defer { hosted.finish() }
      var snapshot = HostedStore.snapshot(
        connection: .closed(reason: .tabEnded(reason: nil, detail: "")))
      snapshot.nav?.canGoBack = true
      snapshot.nav?.canGoForward = true
      await hosted.hostSends(snapshot)
      let page = OffscreenPage { RemoteBrowserToolbar(store: hosted.store) }
      defer { page.close() }
      await page.draw()
      #expect(page.buttons.count == 3)
      #expect(page.buttons.allSatisfy { !$0.isEnabled })
      #expect(page.textFields.isEmpty || page.textFields.allSatisfy { !$0.isEnabled })
    }

    @Test("the address field shows the page, and blank for about:blank")
    func addressField() async throws {
      let hosted = HostedStore()
      defer { hosted.finish() }
      var snapshot = HostedStore.snapshot()
      await hosted.hostSends(snapshot)
      let page = OffscreenPage { RemoteAddressField(store: hosted.store) }
      defer { page.close() }
      await page.draw()
      let field = try #require(page.textFields.first)
      #expect(field.stringValue == "https://example.com/")
      snapshot.nav?.url = "about:blank"
      await hosted.hostSends(snapshot)
      await page.draw()
      #expect(field.stringValue.isEmpty)
    }

    @Test("what a host names draws, however odd", arguments: oddStrings)
    func oddNames(text: String) async {
      let hosted = HostedStore(lastURL: text)
      defer { hosted.finish() }
      var snapshot = HostedStore.snapshot()
      snapshot.profile = text
      snapshot.nav?.url = text
      snapshot.nav?.title = text
      snapshot.control?.handoff = RemoteBrowserHandoff(id: text, reason: text)
      snapshot.control?.owner = .agent
      await hosted.hostSends(snapshot)
      hosted.connector.listener?.onNotice(
        notice: RemoteBrowserNotice(message: text, userFacing: true))
      await letTasksRun()
      let page = OffscreenPage(width: 300, height: 200) {
        RemoteBrowserTabView(store: hosted.store)
      }
      defer { page.close() }
      #expect(await page.draw() > 0)
      #expect(hosted.store.notice == text)
    }

    @Test(
      "loading progress of any value draws",
      arguments: [Double.nan, .infinity, -.infinity, -1, 0, 1, 1e300, .leastNonzeroMagnitude])
    func oddProgress(progress: Double) async {
      let hosted = HostedStore()
      defer { hosted.finish() }
      var snapshot = HostedStore.snapshot()
      snapshot.nav?.loading = true
      snapshot.nav?.progress = progress
      await hosted.hostSends(snapshot)
      let page = OffscreenPage { RemoteBrowserTabView(store: hosted.store) }
      defer { page.close() }
      #expect(await page.draw() > 0)
    }

    @Test(
      "the tab fits any window size",
      arguments: [
        CGSize(width: 1, height: 1), CGSize(width: 40, height: 3000),
        CGSize(width: 4000, height: 10),
      ])
    func oddWindowSizes(size: CGSize) async {
      let hosted = HostedStore()
      defer { hosted.finish() }
      await hosted.hostSends(HostedStore.snapshot())
      let page = OffscreenPage(width: size.width, height: size.height) {
        RemoteBrowserTabView(store: hosted.store)
      }
      defer { page.close() }
      #expect(await page.draw() > 0)
    }

    @Test("appearing shows the tab, and leaving the window hides it")
    func visibility() async {
      let hosted = HostedStore()
      defer { hosted.finish() }
      let page = OffscreenPage { RemoteBrowserTabView(store: hosted.store) }
      await page.draw()
      #expect(hosted.driverCalls.contains("visible true"))
      page.close()
      await letTasksRun()
      #expect(hosted.driverCalls.last == "visible false")
    }

    @Test("the fixture host's video plays in a tab that was never shown")
    func fixtureVideo() async throws {
      let host = FixtureRemoteBrowser(latency: .milliseconds(1))
      host.addTab(id: "t", url: "https://example.com/")
      UserDefaults.standard.removeObject(forKey: RemoteViewportModeDefaults.key)
      let store = RemoteBrowserStore(sessionID: "s", tabID: "t")
      store.pasteboard = MemoryPasteboard()
      let page = OffscreenPage { RemoteBrowserTabView(store: store) }
      defer { page.close() }
      await page.draw()
      store.attach(using: host, mode: .control, hostID: nil)
      defer { store.detach() }
      #expect(try await eventually(seconds: 10) { (store.renderer?.framesEnqueued ?? 0) > 2 })
      #expect(store.renderer?.videoSize != nil)
      await page.draw()
    }
  }

  @MainActor
  @Suite("Remote control strip offscreen", .serialized)
  struct RemoteControlStripRenderTests {
    @Test("the agent browsing offers take over, which reaches the driver")
    func takeOver() async throws {
      let hosted = HostedStore()
      defer { hosted.finish() }
      await hosted.hostSends(HostedStore.snapshot(owner: .agent, holder: .nobody))
      let page = OffscreenPage {
        RemoteBrowserControlStrip(store: hosted.store).buttonStyle(.borderless)
      }
      defer { page.close() }
      await page.draw()
      try #require(page.buttons.count == 1)
      page.buttons[0].performClick(nil)
      #expect(hosted.driverCalls.last == "take")
    }

    @Test("being in control offers hand back, which reaches the driver")
    func handBack() async throws {
      let hosted = HostedStore()
      defer { hosted.finish() }
      await hosted.hostSends(HostedStore.snapshot())
      let page = OffscreenPage {
        RemoteBrowserControlStrip(store: hosted.store).buttonStyle(.borderless)
      }
      defer { page.close() }
      await page.draw()
      try #require(page.buttons.count == 1)
      page.buttons[0].performClick(nil)
      #expect(hosted.driverCalls.last == "release")
    }

    @Test("another device in control, and watching, offer nothing")
    func nothingToOffer() async {
      let hosted = HostedStore()
      defer { hosted.finish() }
      let snapshots = [
        HostedStore.snapshot(owner: .user, holder: .other),
        HostedStore.snapshot(connection: .attached(mode: .view), owner: .agent, holder: .nobody),
        HostedStore.snapshot(connection: .connecting),
      ]
      let page = OffscreenPage {
        RemoteBrowserControlStrip(store: hosted.store).buttonStyle(.borderless)
      }
      defer { page.close() }
      for snapshot in snapshots {
        await hosted.hostSends(snapshot)
        await page.draw()
        #expect(page.buttons.isEmpty)
      }
    }
  }

  @MainActor
  @Suite("Remote viewport menu offscreen", .serialized)
  struct RemoteViewportMenuRenderTests {
    nonisolated private static let oddSizes = [
      RemoteViewportSize(width: .max, height: .min, dpr: .infinity),
      RemoteViewportSize(width: 0, height: 0, dpr: .nan),
      RemoteViewportSize(width: -1, height: 1, dpr: -1),
      RemoteViewportSize(width: 1280, height: 800, dpr: 1e300),
    ]

    @Test("the toolbar's menu names every mode")
    func everyMode() async {
      let modes: [RemoteViewportMode] =
        [.keep, .fitWindow, .mobile(site: false), .mobile(site: true)]
        + (Self.oddSizes + RemoteViewportMode.presets).map { .fixed($0) }
      let hosted = HostedStore()
      defer { hosted.finish() }
      let page = OffscreenPage { RemoteViewportMenu(store: hosted.store) }
      defer { page.close() }
      for mode in modes {
        hosted.store.viewportMode = mode
        #expect(await page.draw() > 0)
      }
    }

    @Test("the items choose a mode")
    func choosingAMode() async throws {
      let hosted = HostedStore(mode: .fixed(RemoteViewportSize(width: 640, height: 480, dpr: 2)))
      defer { hosted.finish() }
      await hosted.hostSends(HostedStore.snapshot())
      let page = OffscreenPage {
        VStack { RemoteViewportMenuItems(store: hosted.store, editingCustomSize: .constant(false)) }
          .buttonStyle(.borderless)
      }
      defer { page.close() }
      await page.draw()
      #expect(page.popupTitles == ["Set Remote Size (640 \u{00D7} 480 @2x)"])
      try #require(page.buttons.count == 2)
      page.buttons[1].performClick(nil)
      #expect(hosted.store.viewportMode == .fitWindow)
      await page.draw()
      #expect(page.popupTitles == ["Set Remote Size"])
      page.buttons[0].performClick(nil)
      #expect(hosted.store.viewportMode == .keep)
    }

    @Test("not being in control says when the choice applies")
    func notInControl() async {
      let hosted = HostedStore()
      defer { hosted.finish() }
      await hosted.hostSends(HostedStore.snapshot(owner: .agent, holder: .nobody))
      let page = OffscreenPage {
        VStack { RemoteViewportMenuItems(store: hosted.store, editingCustomSize: .constant(false)) }
      }
      defer { page.close() }
      #expect(await page.draw() > 0)
    }

    @Test("the custom size form opens on any stored size", arguments: oddSizes)
    func customSizeForm(size: RemoteViewportSize) async throws {
      let page = OffscreenPage { RemoteCustomSizeSheet(initial: size) { _ in } }
      defer { page.close() }
      #expect(await page.draw() > 0)
      #expect(page.textFields.count == 2)
      let sharp = try #require(page.buttons.last)
      #expect(sharp.state == (size.dpr > 1 ? .on : .off))
    }

    @Test("the custom size form shows the size it was given")
    func customSizeValues() async throws {
      let page = OffscreenPage {
        RemoteCustomSizeSheet(initial: RemoteViewportSize(width: 640, height: 480)) { _ in }
      }
      defer { page.close() }
      await page.draw()
      try #require(page.textFields.count == 2)
      #expect(page.textFields[0].integerValue == 640)
      #expect(page.textFields[1].integerValue == 480)
    }
  }
#endif
