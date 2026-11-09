import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import Testing

@testable import OmnigentStores

private let address = "https://omnigent.example.com"

private func payload(decision: String? = "d1") -> SupervisionPayload {
  SupervisionPayload(
    serverURL: address, sessionID: "child", openSessionID: "parent", decisionID: decision,
    kind: .approval)
}

/// What a notification keeps, and what it says when an answer doesn't happen.
@MainActor
@Suite("Supervision messages", .timeLimit(.minutes(1)))
struct SupervisionMessageTests {
  @Test("The strings the Mac hands back with an action read as the payload they came from")
  func contextRoundTrip() throws {
    let original = payload()
    #expect(try SupervisionPayload(context: original.context) == original)

    let withoutDecision = payload(decision: nil)
    #expect(withoutDecision.context["decision_id"] == nil)
    #expect(try SupervisionPayload(context: withoutDecision.context) == withoutDecision)
  }

  @Test("Strings missing a field are refused, not guessed at")
  func malformedContext() {
    #expect(throws: SupervisionError.self) {
      try SupervisionPayload(context: ["server_url": address])
    }
  }

  @Test("A failed action says why, in its own notification that doesn't offer the action again")
  func failureNotification() {
    let content = SupervisionContent.failure(
      .requestGone, payload: payload(), sessionTitle: "Fix the build")
    #expect(content.identifier == "\(address)/c/child/failure")
    #expect(content.threadIdentifier == "\(address)/c/parent")
    #expect(content.title.contains("Fix the build"))
    #expect(content.body == SupervisionError.requestGone.message)
    #expect(content.category == .update)
    #expect(content.payload.decisionID == nil)
    #expect(content.payload.openSessionID == "parent")
  }

  @Test(
    "Each failure reads as something to do next",
    arguments: [
      (SupervisionError.malformedPayload("x"), "This notification can't be answered."),
      (SupervisionError.notConnected, "Not signed in"),
      (SupervisionError.requestGone, "already answered"),
      (SupervisionError.actionNotOffered, "Open Omnigent"),
      (SupervisionError.needsApp, "Open Omnigent"),
      (SupervisionError.emptyReply, "The reply was empty"),
      (SupervisionError.replyDoesNotMatch, "didn't match"),
      (SupervisionError.authenticationFailed, "authentication failed"),
      (SupervisionError.failed("HTTP 500"), "Couldn't answer: HTTP 500"),
    ])
  func messages(error: SupervisionError, expected: String) {
    #expect(error.message.contains(expected), "\(error.message)")
  }

  @Test("The core's refusals map to what the notification can say")
  func errorMapping() {
    #expect(
      ConnectionStore.supervisionError(
        CoreError.Terminal(kind: .forbidden, message: "x", requiresSignIn: true)) == .notConnected)
    #expect(
      ConnectionStore.supervisionError(
        CoreError.Session(
          kind: .notConnected, message: "x", detail: nil, requiresSignIn: false,
          deliveryUncertain: false)) == .notConnected)
    #expect(
      ConnectionStore.supervisionError(CoreError.InvalidState(message: "nope"))
        == .failed("nope"))
  }

  @Test("Answering through the store reads pending requests and reports the server's refusal")
  func answersThroughTheStore() async throws {
    let server = RouteServer()
    let store = try await connectedStore(server)
    #expect(store.supervisedServerURL == "http://127.0.0.1:6767")

    server.fail("/v1/sessions/conv_a/approvals", status: 500)
    server.fail("/v1/sessions/conv_a", status: 500)
    await #expect(throws: SupervisionError.self) {
      try await store.pendingDecisions(sessionID: "conv_a")
    }
    await #expect(throws: SupervisionError.self) {
      try await store.resolve(sessionID: "conv_a", decisionID: "d1", response: .decline)
    }
  }
}
