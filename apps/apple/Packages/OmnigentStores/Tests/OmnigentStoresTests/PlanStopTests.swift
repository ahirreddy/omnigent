import OmnigentCoreFFI
import Testing

@testable import OmnigentStores

/// The plan's Stop: "Stopping…" from the press until the session is seen to stop, as the web's
/// `usePlanStopping` reads it.
@Suite("Plan stop")
struct PlanStopTests {
  private let stopText = stopPlanMessage(planName: nil)

  /// One settlement read again and again, as the tab reads it on each draw.
  private final class Settlement {
    private var settlement = PlanStopSettlement()

    func stopping(_ stop: PlanStop?, working: Bool, latest: LatestRequest?) -> Bool {
      settlement.stopping(stop, working: working, latest: latest)
    }
  }

  private func request(_ id: String, stop: Bool = false, pending: Bool = false) -> LatestRequest {
    LatestRequest(id: id, isStop: stop, isPending: pending)
  }

  private func row(_ id: String, _ text: String, role: RowRole = .user) -> Row {
    Row(
      id: id, role: role, text: text, isStreaming: false, activity: nil, attachments: [],
      callId: nil, responseId: nil, interrupted: false, author: nil, agent: nil, createdAt: nil,
      isEphemeral: false, isActivityOnly: false)
  }

  @Test("A Stop shows Stopping until it is sent and the session stops, then Continue")
  func stopUntilIdle() {
    let settlement = Settlement()
    var stop = PlanStop(id: 1, baselineRequestID: "u1")
    // Not sent yet: stopping even while the session reads idle.
    #expect(settlement.stopping(stop, working: false, latest: request("u1")))
    stop.sent = true
    #expect(
      settlement.stopping(stop, working: true, latest: request("p1", stop: true, pending: true)))
    #expect(settlement.stopping(stop, working: true, latest: request("s1", stop: true)))
    #expect(!settlement.stopping(stop, working: false, latest: request("s1", stop: true)))
    // A later wake shows no Stopping for a Stop already seen to finish.
    #expect(!settlement.stopping(stop, working: true, latest: request("s1", stop: true)))
  }

  @Test("Another request the session takes, here or elsewhere, ends the Stop")
  func followedByAnotherRequest() {
    let settlement = Settlement()
    let stop = PlanStop(id: 1, baselineRequestID: "u1", sent: true)
    #expect(settlement.stopping(stop, working: true, latest: request("s1", stop: true)))
    #expect(!settlement.stopping(stop, working: true, latest: request("u2")))
    #expect(!settlement.stopping(stop, working: false, latest: request("u2")))
    // The latest request when Stop was pressed doesn't count as a follow-up.
    let fresh = Settlement()
    #expect(fresh.stopping(stop, working: true, latest: request("u1")))
  }

  @Test("Without a Stop from here, the transcript's latest stop message stands in")
  func transcriptStandsIn() {
    let settlement = Settlement()
    #expect(settlement.stopping(nil, working: true, latest: request("s1", stop: true)))
    #expect(!settlement.stopping(nil, working: true, latest: request("u1")))
    // One still on its way may yet fail, so it doesn't count.
    #expect(
      !settlement.stopping(nil, working: true, latest: request("p", stop: true, pending: true)))
    #expect(!settlement.stopping(nil, working: false, latest: request("s1", stop: true)))
    #expect(!settlement.stopping(nil, working: true, latest: request("s1", stop: true)))
    // A newer stop message counts again.
    #expect(settlement.stopping(nil, working: true, latest: request("s2", stop: true)))
  }

  @Test("The latest request is the newest message on its way, else the newest user row")
  func latestRequest() {
    let rows = [row("u1", "Go"), row("s1", stopText), row("a1", "Stopping.", role: .assistant)]
    #expect(LatestRequest.of(rows: rows, pending: []) == request("s1", stop: true))
    #expect(
      LatestRequest.of(rows: rows, pending: [row("p1", "Continue")])
        == request("p1", pending: true))
    #expect(LatestRequest.of(rows: [row("a1", "Hi", role: .assistant)], pending: []) == nil)
  }
}
