import AppKit
import Foundation
import OWLProtocol
import Testing

@testable import OmnigentWebLayer

/// Everything a host can say to a view, with values no well-behaved host would send.
@MainActor
@Suite("View messages from a broken host")
struct HostileViewMessageTests {
  @Test func navigationStateFollowsTheHost() throws {
    let fixture = ProtocolFixture()
    var changes = 0
    fixture.webView.onStateChange = { changes += 1 }
    try fixture.receive(.urlChanged, WireEncoder().string(.URL, "https://a.example/"))
    #expect(fixture.webView.url?.host() == "a.example")
    try fixture.receive(.urlChanged, WireEncoder().string(.URL, "http://[bad"))
    #expect(fixture.webView.url == nil)
    try fixture.receive(
      .titleChanged, WireEncoder().string(.title, String(repeating: "W", count: 100_000)))
    #expect(fixture.webView.title.count == 100_000)
    try fixture.receive(.titleChanged, WireEncoder())
    #expect(fixture.webView.title.isEmpty)
    fixture.webView.lastError = .notReady
    try fixture.receive(
      .loadingState,
      WireEncoder().bool(.isLoading, true).bool(.canGoBack, true).bool(.canGoForward, true))
    #expect(fixture.webView.isLoading && fixture.webView.canGoBack && fixture.webView.canGoForward)
    #expect(fixture.webView.lastError == nil)
    try fixture.receive(.loadProgress, WireEncoder().double(.progress, .nan))
    #expect(fixture.webView.estimatedProgress.isNaN)
    try fixture.receive(.loadProgress, WireEncoder())
    #expect(fixture.webView.estimatedProgress == 0)
    #expect(changes == 7)
  }

  @Test func loadErrorsAndTheBlocksBehindThem() throws {
    let fixture = ProtocolFixture()
    let aborted = Int64(WebView.netErrorAborted)
    try fixture.receive(.loadError, WireEncoder().i64(.errorCode, .min).string(.text, "boom"))
    guard case .navigationFailed(nil, let code, "boom") = fixture.webView.lastError else {
      Issue.record("expected a failure, got \(String(describing: fixture.webView.lastError))")
      return
    }
    #expect(code == Int(Int64.min))
    try fixture.receive(.loadError, WireEncoder().i64(.errorCode, aborted))
    #expect(fixture.webView.lastError == .navigationCancelled(url: nil))
    try fixture.receive(.navigationBlocked, WireEncoder())
    #expect(
      fixture.webView.lastError
        == .navigationBlocked(url: nil, reason: "Blocked by the navigation rules."))
    // The abort that follows a block keeps the block's reason.
    try fixture.receive(.loadError, WireEncoder().i64(.errorCode, aborted))
    #expect(
      fixture.webView.lastError
        == .navigationBlocked(url: nil, reason: "Blocked by the navigation rules."))
  }

  @Test func pageEventsAreReported() throws {
    let fixture = ProtocolFixture()
    var events: [WebViewEvent] = []
    fixture.webView.onEvent = { events.append($0) }
    try fixture.receive(.rendererGone, WireEncoder().i64(.status, .min).i64(.errorCode, .max))
    #expect(fixture.webView.lastError?.errorDescription?.contains("\(Int64.min)") == true)
    try fixture.receive(.downloadBlocked, WireEncoder().string(.URL, "not a url"))
    try fixture.receive(.featureBlocked, WireEncoder())
    #expect(fixture.webView.lastError == .featureBlocked(feature: "A browser feature", detail: ""))
    #expect(events.count == 3)
    try fixture.receive(.cursorChanged, WireEncoder().u64(.cursor, .max))
    #expect(fixture.webView.cursor == .pointer)
    try fixture.receive(.cursorChanged, WireEncoder().u64(.cursor, OWLCursor.grabbing.rawValue))
    #expect(fixture.webView.cursor == .grabbing)
    try fixture.receive(.layerContext, WireEncoder())
    #expect(
      fixture.webView.lastError == .renderingUnavailable("LayerContext carried no context ID."))
    try fixture.receive(.layerContext, WireEncoder().u64(.contextID, .max))
    #expect(fixture.webView.layerHost.mode == .remoteLayer)
  }

  @Test func theHostClosingAViewRemovesIt() throws {
    let fixture = ProtocolFixture()
    try fixture.receive(.viewClosed, WireEncoder())
    #expect(fixture.webView.status == .closed)
    #expect(fixture.session.views[fixture.webView.id] == nil)
    // Later messages for the closed view are dropped.
    try fixture.receive(.titleChanged, WireEncoder().string(.title, "late"))
    #expect(fixture.webView.title.isEmpty)
    fixture.webView.close()
    #expect(fixture.sent.isEmpty)
  }

  @Test func imeRectsAndSelectionAcceptOddValues() throws {
    let fixture = ProtocolFixture()
    try fixture.receive(
      .imeCompositionChanged, WireEncoder().string(.rects, "[[1,2,3,4],[1,2],[]]"))
    #expect(fixture.webView.compositionCharacterRects == [CGRect(x: 1, y: 2, width: 3, height: 4)])
    try fixture.receive(.imeCompositionChanged, WireEncoder().string(.rects, "not json"))
    #expect(fixture.webView.compositionCharacterRects.isEmpty)
    try fixture.receive(
      .imeCompositionChanged, WireEncoder().string(.rects, "[[1e308,1e308,1e308,1e308]]"))
    #expect(fixture.webView.compositionCharacterRects.count == 1)

    try fixture.receive(
      .textSelectionChanged, WireEncoder().string(.text, "x").i64(.rangeStart, 5).i64(.rangeEnd, 2))
    #expect(fixture.webView.selectedRange == NSRange(location: 5, length: 0))
    try fixture.receive(
      .textSelectionChanged, WireEncoder().i64(.rangeStart, .min).i64(.rangeEnd, .min))
    #expect(fixture.webView.selectedRange.length == 0)
    try fixture.receive(.dragCursor, WireEncoder().u64(.dragOperations, .max))
    #expect(fixture.webView.dragOperation.contains(.copy))
  }

  @Test(
    "A selection wider than Int reports without overflowing")
  func selectionPastInt() throws {
    let fixture = ProtocolFixture()
    try fixture.receive(
      .textSelectionChanged, WireEncoder().i64(.rangeStart, -1).i64(.rangeEnd, .max))
    #expect(fixture.webView.selectedRange.length >= 0)
  }

  @Test func findResultsOfAnySize() async throws {
    let fixture = ProtocolFixture()
    let search = Task { try await fixture.webView.find("needle") }
    #expect(await fixture.eventually { fixture.webView.pendingFind != nil })
    try fixture.receive(.findResult, WireEncoder().bool(.finalUpdate, false).i64(.count, 9))
    #expect(fixture.webView.pendingFind != nil)
    try fixture.receive(
      .findResult, WireEncoder().bool(.finalUpdate, true).i64(.count, .max).i64(.activeMatch, .min))
    let found = try await search.value
    #expect(found.matchCount == .max)
    #expect(found.activeMatch == .min)

    // A second search ends the first with no matches.
    let first = Task { try await fixture.webView.find("a") }
    #expect(await fixture.eventually { fixture.webView.pendingFind != nil })
    let second = Task { try await fixture.webView.find("b", forward: false, caseSensitive: true) }
    #expect(try await first.value.matchCount == 0)
    fixture.webView.stopFinding()
    #expect(try await second.value.matchCount == 0)
    try fixture.receive(.findResult, WireEncoder().bool(.finalUpdate, true).i64(.count, -5))
    #expect(fixture.webView.pendingFind == nil)
    #expect(fixture.last(.stopFind) != nil)
  }

  @Test func presentedFramesCountEvenWithBackwardsClocks() throws {
    let fixture = ProtocolFixture()
    var events: [WebViewEvent] = []
    fixture.webView.onEvent = { events.append($0) }
    try fixture.receive(
      .presented,
      WireEncoder().u64(.hostTimestampNanos, .max).u64(.presentedNanos, 0)
        .u64(.droppedFrames, .max).u64(.hostBlitNanos, .max))
    try fixture.receive(.presented, WireEncoder())
    #expect(fixture.webView.statistics.framesPresented == 2)
    #expect(fixture.webView.statistics.framesDropped == .max)
    #expect(events.count == 1)
  }

  @Test func favIconsAndAudioFromTheHost() throws {
    let fixture = ProtocolFixture()
    try fixture.receive(
      .faviconURLChanged, WireEncoder().string(.JSON, #"["https://a/i.png","http://[bad"]"#))
    #expect(fixture.webView.faviconURLs.count == 1)
    try fixture.receive(.faviconURLChanged, WireEncoder().string(.JSON, "{}"))
    #expect(fixture.webView.lastError != nil)
    #expect(fixture.webView.faviconURLs.count == 1)
    try fixture.receive(.audioStateChanged, WireEncoder().bool(.audible, true).bool(.muted, true))
    #expect(fixture.webView.isAudible && fixture.webView.isAudioMuted)
    // Asking for the muted state it already has sends nothing.
    fixture.webView.setAudioMuted(true)
    #expect(fixture.last(.setAudioMuted) == nil)
  }

  @Test func keysThePageLeftComeBackAsEvents() throws {
    let fixture = ProtocolFixture()
    var events: [NSEvent] = []
    try fixture.receive(.keyUnhandled, WireEncoder())
    try fixture.receive(.keyUnhandled, WireEncoder().u64(.nativeKeyCode, 40))
    fixture.webView.renderer.onUnhandledKeyEvent = { events.append($0) }
    try fixture.receive(
      .keyUnhandled,
      WireEncoder().u64(.nativeKeyCode, .max).u64(.modifiers, .max).u64(.character, .max)
        .u64(.unmodifiedCharacter, .max))
    #expect(events.count == 1)
    #expect(events.first?.keyCode == .max)
    #expect(events.first?.isARepeat == true)
  }

  @Test func messagesTheViewDoesNotKnowAreDropped() throws {
    let fixture = ProtocolFixture()
    // A kind only the client sends has no handler in the view.
    try fixture.receive(.viewCreate, WireEncoder())
    #expect(fixture.webView.lastError == nil)
  }

  @Test(
    "A kind this client does not know is a protocol error")
  func unknownKindsAreReported() throws {
    let fixture = ProtocolFixture()
    fixture.session.handle(
      IncomingMessage(
        kindValue: .max, request: 0, target: fixture.webView.id, protocolMajor: 0,
        fields: try WireDecoder([]), port: nil))
    #expect(fixture.session.lastProtocolError != nil)
  }

  @Test func aKindThisClientDoesNotKnowChangesNothing() throws {
    let fixture = ProtocolFixture()
    let unknown = IncomingMessage(
      kindValue: .max, request: 0, target: fixture.webView.id, protocolMajor: 0,
      fields: try WireDecoder([]), port: nil)
    fixture.webView.handle(unknown)
    fixture.session.handle(unknown)
    #expect(fixture.webView.status == .live)
    #expect(fixture.webView.lastError == nil)
  }

  @Test func startDragWithoutAViewEndsAtOnce() throws {
    let fixture = ProtocolFixture()
    var events: [WebViewEvent] = []
    fixture.webView.onEvent = { events.append($0) }
    try fixture.receive(.startDrag, WireEncoder().string(.dragData, "garbage"))
    #expect(fixture.webView.lastError != nil)
    #expect(fixture.last(.dragSourceEnded) != nil)
    fixture.sent.removeAll()
    try fixture.receive(
      .startDrag, WireEncoder().double(.X, .nan).double(.Y, .infinity).u64(.dragOperations, .max))
    #expect(events == [.dragStarted(WebDragData())])
    #expect(fixture.last(.dragSourceEnded) != nil)
  }
}

extension ProtocolFixture {
  /// Waits, letting other main-actor tasks run, for `condition`.
  func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<400 {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
  }
}
