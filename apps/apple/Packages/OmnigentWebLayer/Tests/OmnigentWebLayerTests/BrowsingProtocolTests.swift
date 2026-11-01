import Foundation
import OWLProtocol
import Testing

@testable import OmnigentWebLayer

@MainActor
@Suite("Protocol 1.2 browsing state")
struct BrowsingProtocolTests {
  @Test func numberingIsStable() {
    #expect(OWL_PROTOCOL_MINOR_BROWSING == 2)
    #expect(OWLMessageKind.setAudioMuted.rawValue == 101)
    #expect(OWLMessageKind.faviconURLChanged.rawValue == 127)
    #expect(OWLMessageKind.navigationHistory.rawValue == 128)
    #expect(OWLMessageKind.audioStateChanged.rawValue == 129)
    #expect(OWLField.muted.rawValue == 125)
    #expect(OWLField.ignoreCache.rawValue == 127)
  }

  @Test func historyFaviconsAndAudioUpdateTheView() throws {
    let fixture = ProtocolFixture()
    try fixture.receive(
      .navigationHistory,
      WireEncoder().string(
        .JSON,
        #"{"index":1,"entries":[{"url":"https://a.example/","title":"A"},{"url":"https://b.example/","title":"B"},{"url":"https://c.example/","title":""}]}"#
      ))
    let history = try #require(fixture.webView.navigationHistory)
    #expect(history.entries.map(\.title) == ["A", "B", ""])
    #expect(history.currentIndex == 1)
    try fixture.receive(
      .faviconURLChanged, WireEncoder().string(.JSON, #"["https://a.example/icon.png"]"#))
    #expect(fixture.webView.faviconURLs.map(\.absoluteString) == ["https://a.example/icon.png"])
    try fixture.receive(.audioStateChanged, WireEncoder().bool(.audible, true).bool(.muted, false))
    #expect(fixture.webView.isAudible && !fixture.webView.isAudioMuted)
  }

  @Test func malformedHistoryIsAnErrorNotADrop() throws {
    let fixture = ProtocolFixture()
    try fixture.receive(.navigationHistory, WireEncoder().string(.JSON, "[1,2]"))
    #expect(fixture.webView.navigationHistory == nil)
    guard case .invalidArgument? = fixture.webView.lastError else {
      Issue.record("expected invalidArgument, got \(String(describing: fixture.webView.lastError))")
      return
    }
  }

  @Test func muteAndHardReloadAreSent() throws {
    let fixture = ProtocolFixture()
    fixture.webView.setAudioMuted(true)
    #expect(fixture.last(.setAudioMuted)?.bool(.muted) == true)
    #expect(fixture.webView.isAudioMuted)
    fixture.webView.reload(ignoringCache: true)
    #expect(fixture.last(.reload)?.bool(.ignoreCache) == true)
  }

  @Test func muteWaitsForTheViewAndNeedsA12Host() throws {
    let fixture = ProtocolFixture()
    fixture.webView.status = .creating
    fixture.webView.setAudioMuted(true)
    #expect(fixture.sent.isEmpty)
    fixture.session.hostMinor = 1
    fixture.webView.status = .live
    fixture.webView.sendMuted()
    #expect(fixture.sent.isEmpty)
    guard case .featureBlocked? = fixture.webView.lastError else {
      Issue.record("expected featureBlocked")
      return
    }
  }
}
