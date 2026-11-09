import Testing

@testable import OmnigentUIComponents

@Suite("A failure shows once")
struct TranscriptFailuresTests {
  private func state(failure: String? = nil, error: String? = nil, rowSaying: String? = nil)
    -> ConversationViewState
  {
    var header = PreviewData.header
    header.failureMessage = failure
    let rows = rowSaying.map { summary in
      [
        PreviewData.activity(
          "failed", .error, title: "Provider error", summary: summary, isFailure: true)
      ]
    }
    return ConversationViewState(header: header, rows: rows ?? [], errorMessage: error)
  }

  @Test("the turn's failure and the same session error are one banner")
  func sameMessage() {
    let failures = TranscriptFailures(state(failure: "boom", error: "boom"))
    #expect(failures.turnFailure == "boom")
    #expect(failures.sessionError == nil)
  }

  @Test("a row saying it leaves no banner at all")
  func rowSaysIt() {
    let failures = TranscriptFailures(state(failure: "boom", error: "boom", rowSaying: "boom"))
    #expect(failures == TranscriptFailures(state()))
    #expect(failures.turnFailure == nil)
  }

  @Test("different failures both show")
  func different() {
    let failures = TranscriptFailures(state(failure: "turn", error: "session", rowSaying: "row"))
    #expect(failures.turnFailure == "turn")
    #expect(failures.sessionError == "session")
  }
}
