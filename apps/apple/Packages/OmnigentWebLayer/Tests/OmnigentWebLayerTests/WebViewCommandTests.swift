import AppKit
import Foundation
import OWLProtocol
import Testing

@testable import OmnigentWebLayer

@MainActor
@Suite("View commands")
struct WebViewCommandTests {
  @Test func commandsWaitForALiveView() throws {
    let fixture = ProtocolFixture()
    let waiting = fixture.session.profile(identifier: "w", persistence: .ephemeral).makeWebView()
    waiting.status = .waitingForHost
    fixture.sent.removeAll()
    waiting.goBack()
    waiting.goForward()
    waiting.stopLoading()
    waiting.reload()
    waiting.setZoomLevel(.nan)
    waiting.stopFinding()
    waiting.updateGeometry(
      size: CGSize(width: CGFloat.nan, height: -1), scale: .nan, screenOrigin: .zero)
    waiting.setVisible(false)
    waiting.setFocused(true)
    #expect(fixture.sent.isEmpty)
    #expect(throws: WebLayerError.notReady) { try waiting.showDevTools() }
    #expect(waiting.zoomLevel.isNaN)
  }

  @Test func liveCommandsReachTheHost() throws {
    let fixture = ProtocolFixture()
    let view = fixture.webView
    view.goBack()
    view.goForward()
    view.stopLoading()
    view.reload()
    view.setZoomLevel(.infinity)
    view.setFocused(true)
    view.setVisible(false)
    view.updateGeometry(
      size: CGSize(width: CGFloat.nan, height: -5), scale: 0,
      screenOrigin: CGPoint(x: CGFloat.infinity, y: 0))
    try view.showDevTools()
    let kinds = fixture.sent.map(\.kind)
    #expect(
      kinds == [
        .goBack, .goForward, .stop, .reload, .setZoom, .viewFocus, .viewVisibility, .viewResize,
        .showDevTools,
      ])
    #expect(fixture.last(.viewResize)?.double(.height) == 1)
    #expect(fixture.last(.setZoom)?.double(.zoomLevel) == .infinity)
    // The same geometry again is not sent.
    fixture.sent.removeAll()
    view.setFocused(true)
    view.setVisible(false)
    #expect(fixture.sent.isEmpty)
  }

  @Test func aViewRenderingOffscreenStaysVisible() {
    let fixture = ProtocolFixture()
    fixture.webView.setVisible(false)
    #expect(!fixture.webView.isVisible)
    fixture.webView.rendersOffscreen = true
    #expect(fixture.webView.isVisible)
    fixture.webView.setVisible(false)
    #expect(fixture.webView.isVisible)
  }

  @Test func loadRemembersTheURLUntilTheViewExists() throws {
    let fixture = ProtocolFixture()
    let url = try #require(URL(string: "https://a.example/"))
    let view = fixture.session.profile(identifier: "l", persistence: .ephemeral).makeWebView()
    view.status = .creating
    view.load(url)
    #expect(view.navigationPendingCreation)
    fixture.sent.removeAll()
    view.setZoomLevel(1)
    view.setFocused(true)
    view.setAudioMuted(true)
    try fixture.receive(.viewCreated, target: view.id, WireEncoder())
    #expect(view.status == .live)
    let kinds = fixture.sent.map(\.kind)
    #expect(kinds.contains(.navigate) && kinds.contains(.setZoom) && kinds.contains(.setAudioMuted))
    #expect(kinds.contains(.viewFocus) && kinds.contains(.setNavigationRules))
    #expect(!view.navigationPendingCreation)
    view.close()
    view.load(url)
    #expect(fixture.last(.viewClose) != nil)
  }

  @Test func reloadOfALostViewRecoversTheSession() {
    let fixture = ProtocolFixture()
    fixture.session.state = .crashed(.notReady)
    fixture.webView.status = .unavailable(.notReady)
    fixture.webView.lastError = .notReady
    fixture.webView.reload()
    #expect(fixture.webView.status == .waitingForHost)
    #expect(fixture.webView.lastError == nil)
    guard case .failed(.hostNotBundled) = fixture.session.state else {
      Issue.record("the session should have tried to launch: \(fixture.session.state)")
      return
    }
  }

  @Test func agentInputFailsPlainlyWhenItCannotBeSent() {
    let fixture = ProtocolFixture()
    let renderer = fixture.webView.renderer
    fixture.webView.status = .unavailable(.launchFailed("x"))
    #expect(throws: WebLayerError.launchFailed("x")) { try renderer.agentMove(to: .zero) }
    fixture.webView.status = .creating
    #expect(throws: WebLayerError.notReady) { try renderer.agentMove(to: .zero) }
    fixture.webView.close()
    #expect(throws: WebLayerError.viewClosed) { try renderer.agentPress(.enter) }
    let orphan = WebContentRenderer(webView: fixture.webView)
    orphan.webView = nil
    #expect(throws: WebLayerError.viewClosed) { try orphan.agentInsertText("x") }
    #expect(throws: WebLayerError.viewClosed) { try orphan.agentClick(at: .zero) }
  }

  @Test func agentPointerInputTakesAnyNumbers() throws {
    let fixture = ProtocolFixture()
    let renderer = fixture.webView.renderer
    let odd = CGPoint(x: CGFloat.nan, y: CGFloat.infinity)
    try renderer.agentClick(at: odd, button: .right, clickCount: .min, modifiers: [.command])
    try renderer.agentClick(at: odd, button: .middle, clickCount: .max)
    try renderer.agentScroll(at: odd, deltaX: .nan, deltaY: -.infinity)
    #expect(fixture.sent.count == 7)
    #expect(fixture.sent[1].fields.u64(.clickCount) == 1)
    #expect(fixture.sent[4].fields.u64(.clickCount) == UInt64(Int.max))
  }

  @Test func agentTextTakesAnyCharacters() throws {
    let fixture = ProtocolFixture()
    let renderer = fixture.webView.renderer
    try renderer.agentType("a\n😀\r\n\u{0}e\u{0301}")
    #expect(fixture.sent.count >= 15)
    fixture.sent.removeAll()
    try renderer.agentInsertText(String(repeating: "W", count: 100_000))
    #expect(fixture.last(.imeCommitText)?.bool(.agentInput) == true)
    // An old host gets key presses instead of an IME commit.
    fixture.session.hostMinor = 0
    fixture.sent.removeAll()
    try renderer.agentInsertText("a")
    #expect(fixture.sent.map(\.kind).allSatisfy { $0 == .inputKey })
  }

  @Test func userInputOnlyGoesToANewEnoughHost() {
    let fixture = ProtocolFixture()
    let renderer = fixture.webView.renderer
    renderer.dragEntered(WebDragData(text: "x"), at: .zero, operations: .copy)
    renderer.dragUpdated(at: CGPoint(x: CGFloat.nan, y: 0), operations: [], modifiers: .command)
    renderer.dragExited()
    renderer.performDrop(at: .zero)
    renderer.dragSourceEnded(at: .zero, operation: .move)
    renderer.finishComposing(keepSelection: true)
    renderer.cancelComposition()
    #expect(fixture.sent.count == 7)
    fixture.session.hostMinor = 0
    fixture.sent.removeAll()
    renderer.dragExited()
    renderer.cancelComposition()
    #expect(fixture.sent.isEmpty)
  }

  @Test("IME ranges at NSNotFound are ignored or sent, without overflowing")
  func rangesPastInt() {
    let fixture = ProtocolFixture()
    let renderer = fixture.webView.renderer
    let huge = NSRange(location: Int.max, length: 5)
    renderer.setComposition("x", selectedRange: huge, replacementRange: nil)
    renderer.setComposition(
      "x", selectedRange: NSRange(location: 0, length: 0), replacementRange: huge)
    renderer.commitText("x", replacementRange: NSRange(location: Int.max - 1, length: 5))
    #expect(fixture.sent.count == 3)
  }

  @Test func imeRangesInBounds() {
    let fixture = ProtocolFixture()
    let renderer = fixture.webView.renderer
    let none = NSRange(location: NSNotFound, length: 0)
    renderer.setComposition("", selectedRange: none, replacementRange: none)
    renderer.setComposition(
      "x", selectedRange: NSRange(location: -5, length: -5), replacementRange: nil)
    renderer.commitText("x", replacementRange: none)
    #expect(fixture.sent.count == 3)
    #expect(fixture.sent[0].fields.i64(.replaceStart) == nil)
    #expect(fixture.sent[1].fields.i64(.rangeEnd) == -10)
  }
}
