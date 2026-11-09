import AppKit
import Foundation
import OWLProtocol
import OmnigentBrowser
import Testing

#if os(macOS)
  @testable import OmnigentBrowserChromium
  @testable import OmnigentWebLayer

  @MainActor
  @Suite("Chromium tab")
  struct ChromiumTabTests {
    @Test func theTabSendsWhatItIsAsked() throws {
      let fixture = try ChromiumTabFixture()
      let tab = fixture.tab
      tab.goBack()
      tab.goForward()
      tab.reload()
      tab.reload(ignoringCache: true)
      tab.stopLoading()
      tab.stopFinding()
      tab.setAudioMuted(true)
      tab.load(try #require(URL(string: "https://example.test/")))
      let kinds = Set(fixture.sent.map(\.kind))
      for kind: OWLMessageKind in [.goBack, .goForward, .reload, .stop, .navigate, .stopFind] {
        #expect(kinds.contains(kind), "\(kind)")
      }
      #expect(tab.engineRestoreData == nil)
      #expect(!tab.restoreEngineState(Data([1, 2])))
      #expect(tab.agentInput.isRendererDirect)
      #expect(!tab.agentInput.needsHostWindow)
    }

    @Test func zoomTakesAnyFactorWithoutTrapping() throws {
      let fixture = try ChromiumTabFixture()
      let factors: [Double] = [
        0, -1, .nan, Double.infinity, -Double.infinity, .leastNonzeroMagnitude,
        .greatestFiniteMagnitude, 1,
      ]
      for factor in factors {
        fixture.tab.setZoomFactor(factor)
        _ = fixture.tab.state.zoomFactor
      }
      fixture.tab.setZoomFactor(1.44)
      #expect(abs(fixture.webView.zoomLevel - 2) < 1e-9)
      #expect(abs(fixture.tab.state.zoomFactor - 1.44) < 1e-9)
    }

    @Test func aDeniedLoadIsReportedAndNotSent() throws {
      let fixture = try ChromiumTabFixture()
      let url = try #require(URL(string: "https://example.test/"))
      fixture.tab.urlPolicy = DenyEverything()
      #expect(fixture.webView.navigationRules != nil)
      fixture.sent.removeAll()
      fixture.tab.load(url)
      #expect(fixture.sent.isEmpty)
      #expect(
        fixture.tab.state.lastError == .navigationBlocked(url: url, reason: "refused in a test"))
      fixture.tab.urlPolicy = nil
      #expect(fixture.webView.navigationRules == nil)
      fixture.tab.popupPolicy = .block
      #expect(fixture.webView.popupPolicy == .block)
    }

    @Test func historyFallsBackToTheCurrentPage() throws {
      let fixture = try ChromiumTabFixture()
      #expect(fixture.tab.navigationHistory == .empty)
      let page = try #require(URL(string: "https://example.test/page"))
      fixture.webView.url = page
      fixture.webView.title = "\u{0}"
      #expect(fixture.tab.navigationHistory.entries.map(\.url) == [page])
      #expect(fixture.tab.navigationHistory.currentIndex == 0)
      #expect(
        try fixture.tab.viewSourceURL().absoluteString == "view-source:\(page.absoluteString)")
      try fixture.receive(
        .navigationHistory,
        WireEncoder().string(
          .JSON, #"{"currentIndex":99,"entries":[{"url":"https://a.test/","title":"A"}]}"#))
      _ = fixture.tab.navigationHistory
      try fixture.receive(.navigationHistory, WireEncoder().string(.JSON, "[1,2]"))
      _ = fixture.tab.navigationHistory
    }

    @Test func viewSourceNeedsAPage() throws {
      let fixture = try ChromiumTabFixture()
      #expect(throws: BrowserError.invalidURL("view-source")) {
        try fixture.tab.viewSourceURL()
      }
    }

    @Test func printingNeedsAWindow() async throws {
      let fixture = try ChromiumTabFixture()
      await #expect(throws: BrowserError.printFailed("The page is not in a window.")) {
        try await fixture.tab.printPage()
      }
    }

    @Test func requestsWithoutAChannelAreNotReady() async throws {
      let fixture = try ChromiumTabFixture()
      fixture.session.outgoingTap = nil
      await #expect(throws: BrowserError.tabNotReady) {
        _ = try await fixture.tab.evaluateJavaScript("1")
      }
      await #expect(throws: BrowserError.tabNotReady) {
        _ = try await fixture.tab.takeSnapshotPNG()
      }
      await #expect(throws: BrowserError.tabNotReady) {
        _ = try await fixture.tab.find("", forward: true, caseSensitive: false)
      }
      #expect(throws: BrowserError.tabNotReady) { try fixture.tab.showDevTools() }
    }

    @Test("DevTools open through the host")
    func showsDevTools() throws {
      let fixture = try ChromiumTabFixture()
      try fixture.tab.showDevTools()
      #expect(fixture.last(.showDevTools) != nil)
    }

    @Test func requestsConvertTheirRepliesAndFailures() async throws {
      let fixture = try ChromiumTabFixture()
      try fixture.connect()
      defer { fixture.session.tearDownConnection() }
      let tab = fixture.tab
      let good = Task { try await tab.evaluateJavaScript("1") }
      try await fixture.answer(
        WireEncoder().bool(.success, true).string(.JSON, #"{"result":{"value":2}}"#))
      #expect(try await good.value == .number(2))
      let bad = Task { try await tab.evaluateJavaScript("1") }
      try await fixture.answer(WireEncoder().string(.JSON, #"{"message":"nope"}"#))
      await #expect(
        throws: BrowserError.devToolsFailed(method: "Runtime.evaluate", message: "nope")
      ) {
        try await bad.value
      }
      let png = Task { try await tab.takeSnapshotPNG() }
      try await fixture.answer(WireEncoder().bool(.success, true).bytes(.PNG, [1]))
      #expect(try await png.value == Data([1]))
      let blank = Task { try await tab.takeSnapshotPNG() }
      try await fixture.answer(WireEncoder().bool(.success, true))
      await #expect(throws: BrowserError.self) { try await blank.value }
      let lost = Task { try await tab.find("x", forward: false, caseSensitive: true) }
      #expect(await fixture.eventually { fixture.webView.pendingFind != nil })
      tab.close()
      #expect(try await lost.value.matchFound == false)
    }

    @Test func closingIsSeenByTheStateAndRepeats() throws {
      let fixture = try ChromiumTabFixture()
      fixture.tab.close()
      fixture.tab.close()
      #expect(fixture.tab.state.isClosed)
      #expect(fixture.webView.status == .closed)
      #expect(throws: BrowserError.tabClosed) { try fixture.agentInput().insertText("x") }
    }

    @Test func hostStateFollowsMessages() throws {
      let fixture = try ChromiumTabFixture()
      try fixture.receive(.audioStateChanged, WireEncoder().bool(.audible, true).bool(.muted, true))
      fixture.webView.zoomLevel = .nan
      fixture.tab.syncState()
      #expect(fixture.tab.state.isAudible)
      #expect(fixture.tab.state.isMuted)
      #expect(fixture.tab.state.zoomFactor.isNaN)
      fixture.webView.zoomLevel = .infinity
      fixture.tab.syncState()
      #expect(fixture.tab.state.zoomFactor == .infinity)
    }
  }

  @MainActor
  @Suite("Chromium agent input")
  struct ChromiumAgentInputTests {
    private let everyKey: [BrowserAgentKey] = [
      .enter, .tab, .escape, .backspace, .delete, .arrowLeft, .arrowRight, .arrowUp, .arrowDown,
      .home, .end, .pageUp, .pageDown, .character("a"), .character("😀"), .character("\u{0}"),
      .character("👩‍👩‍👧‍👦"),
    ]

    @Test func everyKeyWithEveryModifierIsSent() throws {
      let fixture = try ChromiumTabFixture()
      let all: BrowserAgentModifiers = [.shift, .control, .option, .command]
      for key in everyKey {
        fixture.sent.removeAll()
        try fixture.agentInput().press(key, modifiers: [])
        #expect(!fixture.sent.isEmpty, "\(key)")
        try fixture.agentInput().press(key, modifiers: all)
      }
    }

    @Test func scrollDeltasFlipSignForChromium() throws {
      let fixture = try ChromiumTabFixture()
      try fixture.agentInput().scroll(at: .zero, deltaX: 3, deltaY: -4)
      let wheel = try #require(fixture.last(.inputMouse))
      #expect(wheel.double(.deltaX) == -3)
      #expect(wheel.double(.deltaY) == 4)
    }

    @Test func oddNumbersReachTheWireWithoutTrapping() throws {
      let fixture = try ChromiumTabFixture()
      let input = try fixture.agentInput()
      let numbers: [Double] = [
        .nan, .infinity, -.infinity, .greatestFiniteMagnitude, .leastNonzeroMagnitude, -0.0,
      ]
      for number in numbers {
        let point = CGPoint(x: number, y: number)
        try input.scroll(at: point, deltaX: number, deltaY: number)
        for count in [Int.min, -1, 0, 1, Int.max] {
          try input.click(at: point, clickCount: count)
        }
      }
      for text in ["", "\u{0}", String(repeating: "W", count: 100_000), "\u{202E}x", "\n\r\t"] {
        try input.insertText(text)
      }
    }

    @Test func aHostBeforeBrowserUIGetsTextAsKeyPresses() throws {
      let fixture = try ChromiumTabFixture()
      fixture.session.hostMinor = 0
      try fixture.agentInput().insertText("a\nb")
      #expect(fixture.sent.contains { $0.kind == .inputKey })
      #expect(!fixture.sent.contains { $0.kind == .imeCommitText })
    }

    @Test func aPreparedViewportTakesAnySize() throws {
      let fixture = try ChromiumTabFixture()
      let sizes = [
        CGSize.zero, CGSize(width: -1, height: -1), CGSize(width: CGFloat.nan, height: .nan),
        CGSize(width: CGFloat.infinity, height: .infinity),
        CGSize(width: CGFloat.greatestFiniteMagnitude, height: 1), CGSize(width: 800, height: 600),
      ]
      let input = try fixture.agentInput()
      for size in sizes { input.prepareForAgent(viewport: size) }
      #expect(fixture.webView.rendersOffscreen)
      #expect(fixture.webView.size == CGSize(width: 800, height: 600))
    }

    @Test func inputAfterTheViewIsGoneReportsAClosedTab() throws {
      var fixture: ChromiumTabFixture? = try ChromiumTabFixture()
      let input = try #require(try fixture?.agentInput())
      fixture?.tab.close()
      fixture = nil
      input.prepareForAgent(viewport: .zero)
      #expect(throws: BrowserError.tabClosed) { try input.click(at: .zero, clickCount: 1) }
      #expect(throws: BrowserError.tabClosed) { try input.scroll(at: .zero, deltaX: 0, deltaY: 0) }
      #expect(throws: BrowserError.tabClosed) { try input.insertText("x") }
      #expect(throws: BrowserError.tabClosed) { try input.press(.enter, modifiers: []) }
    }
  }
#endif
