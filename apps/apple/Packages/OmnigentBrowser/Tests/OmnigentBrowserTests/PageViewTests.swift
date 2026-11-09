#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentBrowser

  /// A controller with an active fake tab.
  @MainActor
  private struct ControllerFixture {
    let provider = FakeProvider()
    let presenter: BrowserPromptPresenter
    let preferences: BrowserPreferences
    let controller: BrowserController

    init(url: String = "https://a.example/page", engine: BrowserEngineKind = .chromium) throws {
      SystemSideEffects.install()
      let defaults = try isolatedDefaults()
      presenter = BrowserPromptPresenter(
        permissionStore: BrowserPermissionStore(defaults: defaults),
        credentialStore: InMemoryBrowserCredentialStore(),
        downloadSettings: BrowserDownloadSettings(defaults: defaults),
        downloadCenter: BrowserDownloadCenter())
      preferences = BrowserPreferences(defaults: defaults, defaultEngine: engine)
      controller = BrowserController(
        profile: .ephemeral("page-tests"), preferences: preferences, provider: provider,
        initialURL: try testURL(url), presenter: presenter)
    }

    var tab: FakeTab {
      get throws { try #require(controller.tab as? FakeTab) }
    }

    func certificate(overridable: Bool = true, answer: @escaping (Bool) -> Void = { _ in })
      throws -> BrowserCertificatePrompt
    {
      BrowserCertificatePrompt(
        url: try testURL("https://bad.example/"), message: "Expired.", errorCode: -201,
        subject: "bad.example", issuer: "Nobody", isOverridable: overridable, answer: answer)
    }
  }

  @MainActor
  @Suite("Page view, off screen", .serialized)
  struct PageViewTests {
    private func page(_ fixture: ControllerFixture, toolbar: Bool = false)
      -> OffscreenWindow<BrowserView>
    {
      OffscreenWindow(
        BrowserView(controller: fixture.controller, showsToolbar: toolbar), width: 800, height: 500)
    }

    @Test("the tab's page view lands in the window as soon as the view appears")
    func hostsThePage() async throws {
      let fixture = try ControllerFixture()
      let screen = page(fixture)
      defer { screen.close() }
      await screen.catchUp()
      #expect(try fixture.tab.platformView.window === screen.window)
    }

    @Test("Go Back refuses a bad certificate; Proceed goes on when the error allows it")
    func certificateInterstitial() async throws {
      let fixture = try ControllerFixture()
      let screen = page(fixture)
      defer { screen.close() }
      await screen.catchUp()
      let tab = try fixture.tab

      var answers: [Bool] = []
      fixture.presenter.tab(
        tab, didRequest: .certificateError(try fixture.certificate { answers.append($0) }))
      await screen.catchUp()
      #expect(screen.drawnButtons.count == 2)
      #expect(try screen.shows("Your connection is not private"))
      #expect(try screen.shows("bad.example may be impersonating the real site. Expired."))
      #expect(try screen.shows("Certificate: bad.example, issued by Nobody. Error -201."))
      #expect(try screen.shows("Proceed to bad.example (unsafe)"))
      try screen.clickDrawnButton(at: 0)
      await screen.catchUp()
      #expect(answers == [false])
      #expect(fixture.presenter.interstitial(for: tab) == nil)

      fixture.presenter.tab(
        tab, didRequest: .certificateError(try fixture.certificate { answers.append($0) }))
      await screen.catchUp()
      try screen.clickDrawnButton(at: 1)
      await screen.catchUp()
      #expect(answers == [false, true])
    }

    @Test("Proceed isn't offered when the error can't be overridden or overrides are off")
    func certificateWithoutProceed() async throws {
      let fixture = try ControllerFixture()
      let screen = page(fixture)
      defer { screen.close() }
      await screen.catchUp()
      let tab = try fixture.tab
      fixture.presenter.tab(
        tab, didRequest: .certificateError(try fixture.certificate(overridable: false)))
      await screen.catchUp()
      #expect(screen.drawnButtons.count == 1)
      fixture.presenter.resolveInterstitial(for: tab, proceed: false)
      fixture.presenter.allowsCertificateOverrides = false
      fixture.presenter.tab(tab, didRequest: .certificateError(try fixture.certificate()))
      await screen.catchUp()
      #expect(screen.drawnButtons.count == 1)
    }

    @Test("a blocked popup can be opened anyway or dismissed")
    func blockedPopup() async throws {
      let fixture = try ControllerFixture()
      let screen = page(fixture)
      defer { screen.close() }
      await screen.catchUp()
      let tab = try fixture.tab

      let target = try testURL("https://popup.example/")
      tab.state.lastBlockedPopup = BrowserBlockedPopup(url: target, reason: "no gesture")
      await screen.catchUp()
      #expect(screen.drawnButtons.count == 2)
      #expect(try screen.shows("Popup blocked: https://popup.example/"))
      try screen.clickDrawnButton(at: 0)
      await screen.catchUp()
      #expect(tab.state.lastBlockedPopup == nil)
      #expect(fixture.provider.engines[.chromium]?.tabs.last?.state.url == target)

      tab.state.lastBlockedPopup = BrowserBlockedPopup(url: target, reason: "no gesture")
      await screen.catchUp()
      try screen.clickDrawnButton(at: 1)
      await screen.catchUp()
      #expect(tab.state.lastBlockedPopup == nil)

      // Nothing to open without an address, so only Dismiss is offered.
      tab.state.lastBlockedPopup = BrowserBlockedPopup(url: nil, reason: "no gesture")
      await screen.catchUp()
      #expect(screen.drawnButtons.count == 1)
    }

    @Test("an engine that won't start offers WebKit and a retry")
    func engineUnavailable() async throws {
      let fixture = try ControllerFixture()
      fixture.provider.failures[.chromium] = .engineFailedToStart(.chromium, reason: "boom")
      let screen = page(fixture)
      defer { screen.close() }
      await screen.catchUp()
      guard case .engineUnavailable = fixture.controller.content else {
        Issue.record("expected the unavailable panel")
        return
      }
      #expect(screen.drawnButtons.count == 2)
      #expect(try screen.shows("Chromium is unavailable"))
      #expect(try screen.shows("Use System (WebKit)"))

      // Retry stays on the failed engine until it recovers.
      try screen.clickDrawnButton(at: 1)
      await screen.catchUp()
      guard case .engineUnavailable = fixture.controller.content else {
        Issue.record("retry should still fail")
        return
      }
      #expect(fixture.provider.requests.filter { $0 == .chromium }.count >= 2)

      try screen.clickDrawnButton(at: 0)
      await screen.catchUp()
      #expect(fixture.controller.activeEngine == .system)
    }

    @Test("the system engine's own failure offers only Retry")
    func systemEngineUnavailable() async throws {
      let fixture = try ControllerFixture(engine: .system)
      fixture.provider.failures[.system] = .engineFailedToStart(.system, reason: "boom")
      let screen = page(fixture)
      defer { screen.close() }
      await screen.catchUp()
      #expect(screen.drawnButtons.count == 1)
      fixture.provider.failures[.system] = nil
      try screen.clickDrawnButton(at: 0)
      await screen.catchUp()
      #expect(fixture.controller.activeEngine == .system)
    }

    @Test("a page error shows over the page; a cancelled load says nothing")
    func errorBanner() async throws {
      let fixture = try ControllerFixture()
      let screen = page(fixture, toolbar: true)
      defer { screen.close() }
      await screen.catchUp()
      let tab = try fixture.tab
      tab.state.report(.navigationFailed(url: tab.state.url, code: -1, message: "Gone."))
      await screen.catchUp()
      #expect(try screen.shows("Gone."))
      tab.state.report(.navigationFailed(url: tab.state.url, code: -999, message: "Stopped."))
      await screen.catchUp()
      #expect(try !screen.shows("Gone."))
      #expect(try screen.shows("Chromium"))
      #expect(screen.nothingOnScreen)
    }

    @Test("switching the preferred engine moves the page over")
    func preferredEngineMovesThePage() async throws {
      let fixture = try ControllerFixture()
      let screen = page(fixture)
      defer { screen.close() }
      await screen.catchUp()
      fixture.preferences.engine = .system
      await screen.catchUp()
      #expect(fixture.controller.activeEngine == .system)
    }
  }

  @MainActor
  @Suite("Browser toolbar, off screen", .serialized)
  struct BrowserToolbarViewTests {
    private func toolbar(_ fixture: ControllerFixture) -> OffscreenWindow<BrowserView> {
      OffscreenWindow(BrowserView(controller: fixture.controller), width: 800, height: 400)
    }

    @Test("the buttons reach the tab and follow its state")
    func buttons() async throws {
      let fixture = try ControllerFixture()
      let screen = toolbar(fixture)
      defer { screen.close() }
      await screen.catchUp()
      let tab = try fixture.tab
      #expect(!screen.buttons[0].isEnabled)
      #expect(!screen.buttons[1].isEnabled)
      tab.state.canGoBack = true
      tab.state.canGoForward = true
      await screen.catchUp()
      try screen.clickButton(at: 0)
      try screen.clickButton(at: 1)
      try screen.clickButton(at: 2)
      #expect(tab.commands == ["back", "forward", "reload"])
      tab.state.isLoading = true
      tab.state.estimatedProgress = 0.25
      await screen.catchUp()
      try screen.clickButton(at: 2)
      #expect(tab.commands.last == "stop")
      #expect(screen.progressBars.contains { abs($0.doubleValue - 0.25) < 0.01 })
    }

    @Test("the address shows the page and loads what is typed; bad text says why")
    func address() async throws {
      let fixture = try ControllerFixture()
      let screen = toolbar(fixture)
      defer { screen.close() }
      await screen.catchUp()
      let tab = try fixture.tab
      let field = try #require(screen.fields.first)
      #expect(field.stringValue == "https://a.example/page")

      try screen.focusField()
      screen.selectFieldText()
      try screen.type("https://b.example/")
      try screen.pressReturn()
      await screen.catchUp()
      #expect(tab.loads.last == (try testURL("https://b.example/")))
      #expect(field.stringValue == "https://b.example/")

      let loads = tab.loads.count
      try screen.focusField()
      screen.selectFieldText()
      try screen.type("   ")
      try screen.pressReturn()
      await screen.catchUp()
      #expect(tab.loads.count == loads)
      #expect(try screen.shows(BrowserError.invalidURL("   ").localizedDescription))
      try screen.focusField()
      screen.selectFieldText()
      try screen.type("https://c.example/")
      try screen.pressReturn()
      await screen.catchUp()
      #expect(tab.loads.last == (try testURL("https://c.example/")))
      #expect(try !screen.shows(BrowserError.invalidURL("   ").localizedDescription))
      #expect(try screen.shows("Chromium"))
    }

    @Test("the engine picker offers each engine and switches")
    func enginePicker() async throws {
      let fixture = try ControllerFixture()
      let screen = OffscreenWindow(
        BrowserEnginePicker(controller: fixture.controller), width: 300, height: 60)
      defer { screen.close() }
      fixture.controller.activate()
      await screen.catchUp()
      let menu = try screen.popupMenu()
      try screen.choose(BrowserEngineKind.system.displayName, in: menu)
      await screen.catchUp()
      #expect(fixture.controller.activeEngine == .system)
    }

    @Test("the settings row shows the choice and why it can't run")
    func engineSettings() async throws {
      let fixture = try ControllerFixture()
      fixture.provider.failures[.chromium] = .engineFailedToStart(.chromium, reason: "boom")
      let screen = OffscreenWindow(
        Form {
          BrowserEngineSettingsView(preferences: fixture.preferences, provider: fixture.provider)
        }, width: 500, height: 200)
      defer { screen.close() }
      await screen.catchUp()
      #expect(try screen.shows("boom"))
      #expect(try screen.shows("Default: Chromium. Open browser panes switch too."))
      let menu = try screen.popupMenu()
      try screen.choose(BrowserEngineKind.system.displayName, in: menu)
      await screen.catchUp()
      #expect(fixture.preferences.engine == .system)
      #expect(try !screen.shows("boom"))
      #expect(try screen.shows("Default: Chromium"))
    }

    @Test("a rebuilt host hands the page back when its replacement goes")
    func pageContainerHandsThePageBack() {
      let page = BrowserPlatformView(frame: .zero)
      let first = BrowserPageContainer(page: page)
      let second = BrowserPageContainer(page: page)
      #expect(page.superview === second)
      second.release()
      #expect(page.superview === first)
      // Releasing the host without the page leaves the page where it is.
      let third = BrowserPageContainer(page: page)
      first.release()
      #expect(page.superview === third)
      third.release()
      #expect(page.superview === third)
    }
  }
#endif
