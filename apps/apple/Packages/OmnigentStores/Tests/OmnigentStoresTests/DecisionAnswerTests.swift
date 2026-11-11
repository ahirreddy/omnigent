import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import Testing

@testable import OmnigentStores

/// A session waiting on one approval, `ask1`.
private let waitingOnApproval =
  #""pending_elicitations":[{"elicitation_id":"ask1","params":{"message":"Approve?"}}]"#
private let resolvePath = "/v1/sessions/conv_a/elicitations/ask1/resolve"

/// An answered decision card between the tap and the server retiring it.
@MainActor
@Suite("Decision answers", .timeLimit(.minutes(1)))
struct DecisionAnswerTests {
  @Test("An answer shows at once and stays until the server retires the card, sent once")
  func heldUntilRetired() async throws {
    let live = try await LiveComposer(fields: waitingOnApproval)
    let decisions = live.conversation.decisions
    try await eventually("the card") { decisions.pending.count == 1 }
    let card = try #require(decisions.pending.first)
    live.server.route(resolvePath, method: "POST", .json("{}"))
    let post = live.server.hold(resolvePath, method: "POST")

    let answer = Task { await decisions.resolve(card, with: .approve) }
    try await eventually("the answer to reach the server") { post.arrivals == 1 }
    #expect(decisions.answers == ["ask1": .approve])
    #expect(decisions.pending.isEmpty)
    // A second tap while the first answer is out sends nothing and changes nothing.
    await decisions.resolve(card, with: .decline)
    #expect(decisions.answers == ["ask1": .approve])

    // The server takes the answer, and the read that retires the card has not answered yet.
    let reread = live.server.hold("/v1/sessions/conv_a", method: "GET")
    post.release()
    await answer.value
    try await eventually("the read after the answer") { reread.arrivals > 0 }
    #expect(decisions.answers == ["ask1": .approve])
    #expect(decisions.cards.map(\.id) == ["ask1"])
    #expect(decisions.pending.isEmpty)
    #expect(decisions.errors.isEmpty)

    live.server.route("/v1/sessions/conv_a", method: "GET", snapshot(#""pending_elicitations":[]"#))
    reread.release()
    try await eventually("the card to retire") { decisions.cards.isEmpty }
    #expect(decisions.answers.isEmpty)
    #expect(live.server.requests(to: resolvePath, method: "POST").count == 1)
  }

  @Test("A refused answer puts the card back to pending with the error, and only the user retries")
  func refusedThenRetried() async throws {
    let live = try await LiveComposer(fields: waitingOnApproval)
    let decisions = live.conversation.decisions
    try await eventually("the card") { decisions.pending.count == 1 }
    let card = try #require(decisions.pending.first)
    live.server.fail(resolvePath, method: "POST")

    await decisions.resolve(card, with: .approve)
    #expect(decisions.answers.isEmpty)
    #expect(decisions.pending.map(\.id) == ["ask1"])
    #expect(decisions.errors["ask1"] != nil)
    try await live.settle()
    #expect(live.server.requests(to: resolvePath, method: "POST").count == 1)

    live.server.route(resolvePath, method: "POST", .json("{}"))
    await decisions.resolve(card, with: .decline)
    #expect(decisions.answers == ["ask1": .decline])
    #expect(decisions.errors.isEmpty)
    #expect(live.server.requests(to: resolvePath, method: "POST").count == 2)
  }
}
