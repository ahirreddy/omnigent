import Foundation
import OWLProtocol
import Testing

@testable import OmnigentWebLayer

/// What the person reads after a page's renderer process ends.
@MainActor
@Suite("A renderer that ended says how")
struct RendererTerminationTests {
  /// What the host sent, and the sentence it becomes.
  private struct Ending {
    var status: Int64
    var code: Int64
    var hostMessage: String?
    var sentence: String
  }

  private static let endings: [Ending] = [
    Ending(
      status: 0, code: 256, hostMessage: "256", sentence: "It exited unexpectedly (exit code 1)."),
    Ending(
      status: 1, code: 15, hostMessage: "15",
      sentence: "It was killed (signal 15: a request to quit)."),
    Ending(
      status: 1, code: 9, hostMessage: "9", sentence: "It was killed (signal 9: a forced kill)."),
    Ending(
      status: 2, code: 5, hostMessage: "5",
      sentence: "It crashed (signal 5: out of memory or a failed internal check)."),
    Ending(
      status: 2, code: 11, hostMessage: "11",
      sentence: "It crashed (signal 11: an invalid memory access)."),
    Ending(
      status: 2, code: 10, hostMessage: nil,
      sentence: "It crashed (signal 10: an invalid memory access)."),
    Ending(
      status: 2, code: 4, hostMessage: "",
      sentence: "It crashed (signal 4: an illegal instruction)."),
    Ending(status: 2, code: 6, hostMessage: "6", sentence: "It crashed (signal 6: an abort)."),
    Ending(status: 2, code: 31, hostMessage: "31", sentence: "It crashed (signal 31)."),
    Ending(status: 3, code: 0, hostMessage: "0", sentence: "It ran out of memory."),
    Ending(status: 4, code: 2, hostMessage: "2", sentence: "It could not be launched (error 2)."),
    Ending(status: 5, code: 0, hostMessage: "0", sentence: "It failed a code integrity check."),
    Ending(
      status: 9, code: 7, hostMessage: "7",
      sentence: "It ended with unrecognised status 9 (code 7)."),
    // Text from the host that is more than the code is kept.
    Ending(
      status: 4, code: 2, hostMessage: "The helper is missing.",
      sentence: "It could not be launched (error 2). The helper is missing."),
  ]

  @Test func everyEndingIsNamedInWords() throws {
    for ending in Self.endings {
      let fixture = ProtocolFixture()
      var events: [WebViewEvent] = []
      fixture.webView.onEvent = { events.append($0) }
      var fields = WireEncoder().i64(.status, ending.status).i64(.errorCode, ending.code)
      if let hostMessage = ending.hostMessage { fields = fields.string(.message, hostMessage) }
      try fixture.receive(.rendererGone, fields)
      #expect(fixture.webView.lastError == .rendererTerminated(ending.sentence))
      #expect(events == [.rendererTerminated(ending.sentence)])
    }
  }

  @Test func theErrorReadsAsSentences() {
    let error = WebLayerError.rendererTerminated("It ran out of memory.")
    #expect(error.errorDescription == "The page's renderer process stopped. It ran out of memory.")
  }

  @Test func aMessageWithNoFieldsStillSaysSomething() throws {
    let fixture = ProtocolFixture()
    try fixture.receive(.rendererGone, WireEncoder())
    #expect(
      fixture.webView.lastError == .rendererTerminated("It exited unexpectedly (exit code 0)."))
  }
}
