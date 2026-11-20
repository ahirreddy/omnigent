import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

/// A session's pending requests, scripted, and the answers sent to them.
private final class ScriptedRequests: SupervisionDecisionSource {
  var supervisedServerURL: String? = "https://omnigent.example.com"
  var pending: [OmnigentCoreFFI.DecisionCard] = []
  var readError: SupervisionError?
  var resolveError: SupervisionError?
  struct Answer {
    let session: String
    let decision: String
  }

  var answers: [Answer] = []

  func pendingDecisions(sessionID: String) throws(SupervisionError)
    -> [OmnigentCoreFFI.DecisionCard]
  {
    if let readError { throw readError }
    return pending
  }

  func resolve(
    sessionID: String, decisionID: String, response: OmnigentCoreFFI.DecisionResponse
  ) throws(SupervisionError) {
    if let resolveError { throw resolveError }
    answers.append(Answer(session: sessionID, decision: decisionID))
    pending.removeAll { $0.id == decisionID }
  }
}

private func card(_ id: String) -> OmnigentCoreFFI.DecisionCard {
  OmnigentCoreFFI.DecisionCard(
    id: id, carryingSessionId: "s1", targetSessionId: "s1", title: "Run the deploy?",
    detail: "Policy: deploys", message: nil, toolInput: nil, kind: .approval,
    permissions: PermissionOptions(
      allowAllEdits: false, allowAutoMode: false, permissionDirectories: [], rememberLabel: nil,
      plan: nil, command: nil, execPolicyAmendment: nil, persistModes: [], antigravity: nil,
      fileChanges: []),
    phase: nil, policyName: "deploys", acceptsFeedback: false, answered: false)
}

/// An `/approve/<session>/<request>` link's sheet, as the web's approve page.
@MainActor
@Suite("Approval links")
struct ApprovalLinkTests {
  private let request = ApprovalLinkRequest(sessionID: "s1", elicitationID: "e1")

  @Test("a pending request shows its card and answers it; then it reads as approved")
  func approves() async {
    let source = ScriptedRequests()
    source.pending = [card("other"), card("e1")]
    let model = ApprovalLinkModel(request: request, source: source)
    await model.load()
    guard case .pending(let shown, .pending) = model.state else {
      Issue.record("state: \(model.state)")
      return
    }
    #expect(shown.id == "e1")
    await model.respond(.approve)
    #expect(model.state == .submitted(approved: true))
    #expect(source.answers.map(\.decision) == ["e1"])
    #expect(source.answers.first?.session == "s1")
  }

  @Test("a request no longer pending reads as resolved; a refusal keeps the card answerable")
  func resolvedAndRefused() async {
    let source = ScriptedRequests()
    let model = ApprovalLinkModel(request: request, source: source)
    await model.load()
    #expect(model.state == .resolved)

    source.pending = [card("e1")]
    source.resolveError = .failed("The server refused the answer.")
    await model.load()
    await model.respond(.decline)
    guard case .pending(_, .failed(let message)) = model.state else {
      Issue.record("state: \(model.state)")
      return
    }
    #expect(message == "The server refused the answer.")

    source.resolveError = nil
    await model.respond(.decline)
    #expect(model.state == .submitted(approved: false))
  }

  @Test("a failed read says why")
  func failedRead() async {
    let source = ScriptedRequests()
    source.readError = .failed("Server error: 500")
    let model = ApprovalLinkModel(request: request, source: source)
    await model.load()
    #expect(model.state == .failed("Server error: 500"))
  }

  @Test("approving answers count as approved, declining ones as rejected")
  func verdicts() {
    #expect(ApprovalLinkModel.approves(.approveRemembering))
    #expect(ApprovalLinkModel.approves(.answer(value: "yes")))
    #expect(!ApprovalLinkModel.approves(.cancel))
    #expect(!ApprovalLinkModel.approves(.declineWithFeedback(feedback: "not now")))
  }
}
