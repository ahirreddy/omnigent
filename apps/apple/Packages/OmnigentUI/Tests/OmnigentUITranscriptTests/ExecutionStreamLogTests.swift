import Foundation
import Testing

@testable import OmnigentUIComponents

/// The execution logs' SSE view: newer events append, a restarted log replaces what was shown,
/// and times read to the millisecond.
@MainActor
@Suite("Execution logs stream view")
struct ExecutionStreamLogTests {
  private func event(_ index: UInt64) -> ExecutionStreamEvent {
    ExecutionStreamEvent(
      index: index, receivedAt: Date(timeIntervalSince1970: 0), compact: "{}", pretty: "{}")
  }

  @Test("newer events follow those shown, and only the last 500 stay")
  func merged() {
    let shown = [event(0), event(1)]
    #expect(ExecutionStreamLogView.merged(shown, []).map(\.index) == [0, 1])
    #expect(ExecutionStreamLogView.merged(shown, [event(2)]).map(\.index) == [0, 1, 2])
    #expect(ExecutionStreamLogView.merged(shown, [event(0)]).map(\.index) == [0], "restarted")
    let many = (0..<600).map { event(UInt64($0)) }
    let kept = ExecutionStreamLogView.merged([], many)
    #expect(kept.count == ExecutionStreamLogView.limit)
    #expect(kept.first?.index == 100)
  }

  @Test("times show hours, minutes, seconds and milliseconds")
  func time() {
    let shown = ExecutionStreamLogView.time(Date(timeIntervalSince1970: 1_793_502_799.5))
    #expect(shown.wholeMatch(of: /\d{2}:\d{2}:\d{2}\.\d{3}/) != nil, "\(shown)")
    #expect(shown.hasSuffix(":19.500"))
  }
}
