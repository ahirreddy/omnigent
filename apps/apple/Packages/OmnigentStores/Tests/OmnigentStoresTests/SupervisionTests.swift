import Foundation
import OmnigentCoreFFI
import Testing

@testable import OmnigentStores

private let server = "https://omnigent.example.com/api/2.0/omnigent"

private func card(
  _ id: String, kind: DecisionKind = .approval, feedback: Bool = false, answered: Bool = false,
  title: String = "Run `rm -rf /Users/me/project/build`?",
  toolInput: String? = "Bash({\"command\": \"rm -rf /Users/me/project/build\"})"
) -> DecisionCard {
  DecisionCard(
    id: id, carryingSessionId: "parent", targetSessionId: "parent", title: title,
    detail: "Claude wants to call Bash in /Users/me/project", message: "secret plan",
    toolInput: toolInput, kind: kind,
    permissions: PermissionOptions(
      allowAllEdits: false, allowAutoMode: false, permissionDirectories: ["/Users/me/project"],
      rememberLabel: nil, plan: nil, command: nil, execPolicyAmendment: nil,
      persistModes: [], antigravity: nil, fileChanges: []),
    phase: nil, policyName: nil, acceptsFeedback: feedback, answered: answered)
}

private func field(_ key: String, kind: FieldKind = .text, secret: Bool = false) -> FormField {
  FormField(
    key: key, title: key, detail: "", kind: kind, required: true, options: [],
    allowsCustom: false, isSecret: secret, minimum: nil, maximum: nil, minLength: nil,
    maxLength: nil, minItems: nil, maxItems: nil)
}

/// A scripted connection: pending cards per session, and every answer sent.
private final class FakeSource: SupervisionDecisionSource {
  var supervisedServerURL: String? = server
  var pending: [String: [DecisionCard]] = [:]
  var reads: [String] = []
  struct Resolution {
    let session: String
    let decision: String
    let response: DecisionResponse
  }

  var resolved: [Resolution] = []
  var readError: SupervisionError?

  func pendingDecisions(sessionID: String) async throws(SupervisionError) -> [DecisionCard] {
    await Task.yield()
    reads.append(sessionID)
    if let readError { throw readError }
    return pending[sessionID] ?? []
  }

  func resolve(sessionID: String, decisionID: String, response: DecisionResponse)
    async throws(SupervisionError)
  {
    await Task.yield()
    resolved.append(Resolution(session: sessionID, decision: decisionID, response: response))
    pending[sessionID]?.removeAll { $0.id == decisionID }
  }
}

private func payload(decision: String? = "d1", kind: SupervisionKind = .approval)
  -> SupervisionPayload
{
  SupervisionPayload(
    serverURL: server, sessionID: "parent", openSessionID: "parent", decisionID: decision,
    kind: kind)
}

@MainActor
struct SupervisionContentTests {
  @Test("Notification text carries the title and a fixed line, never the request's text")
  func noSensitiveText() {
    let request = card("d1")
    let content = SupervisionContent.decision(
      request, serverURL: server, sessionID: "child", openSessionID: "parent",
      sessionTitle: "Refactor auth")
    #expect(content.title == "Refactor auth")
    #expect(content.body == "Waiting for your approval")
    let shown = content.title + content.body
    for secret in [
      request.title, request.detail, request.message ?? "", request.toolInput ?? "", "/Users",
      "rm -rf",
    ] {
      #expect(!shown.contains(secret))
    }
    // The payload carries identifiers only.
    let values = (content.payload.userInfo["omnigent"] as? [String: any Sendable]) ?? [:]
    #expect(
      Set(values.keys)
        == ["version", "server_url", "session_id", "open_session_id", "kind", "decision_id"])
    #expect(!values.values.contains { "\($0)".contains("rm -rf") || "\($0)".contains("/Users") })
  }

  @Test("Sub-agent requests group under, and open, the parent")
  func groupedPerParent() {
    let first = SupervisionContent.decision(
      card("d1"), serverURL: server, sessionID: "child-a", openSessionID: "parent",
      sessionTitle: "Parent")
    let second = SupervisionContent.decision(
      card("d2", kind: .choice(answerKey: "a", options: ["x"])), serverURL: server,
      sessionID: "child-b", openSessionID: "parent", sessionTitle: "Parent")
    let turn = SupervisionContent.turnEnded(
      .completed, serverURL: server, sessionID: "parent", sessionTitle: "Parent")
    #expect(first.threadIdentifier == second.threadIdentifier)
    #expect(first.threadIdentifier == turn.threadIdentifier)
    #expect(first.identifier != second.identifier)
    // Read through the parent instead, the same request keeps its identifier (one notification).
    let viaParent = SupervisionContent.decision(
      card("d1"), serverURL: server, sessionID: "parent", openSessionID: "parent",
      sessionTitle: "Parent")
    #expect(viaParent.identifier == first.identifier)
    #expect(first.payload.openSessionID == "parent")
    #expect(first.payload.sessionID == "child-a")
    #expect(second.payload.kind == .question)
  }

  @Test("Long and empty titles")
  func titles() {
    #expect(SupervisionContent.title(nil) == "Omnigent")
    #expect(SupervisionContent.title("  ") == "Omnigent")
    let long = SupervisionContent.title(String(repeating: "a", count: 200))
    #expect(long.count == SupervisionContent.maximumTitleLength)
    #expect(long.hasSuffix("\u{2026}"))
  }

  @Test("Categories follow what a card can take from a notification")
  func categories() {
    #expect(SupervisionCategory.of(card("a")) == .approval)
    #expect(SupervisionCategory.of(card("a", feedback: true)) == .approvalWithReply)
    #expect(
      SupervisionCategory.of(card("a", kind: .choice(answerKey: "k", options: []))) == .question)
    #expect(SupervisionCategory.of(card("a", kind: .form(fields: [field("why")]))) == .question)
    #expect(
      SupervisionCategory.of(card("a", kind: .form(fields: [field("a"), field("b")]))) == .update)
    #expect(
      SupervisionCategory.of(card("a", kind: .form(fields: [field("pw", secret: true)])))
        == .update)
    #expect(
      SupervisionCategory.of(card("a", kind: .unsupported(reason: "", externalUrl: nil)))
        == .update)
    #expect(SupervisionCategory.update.actions.isEmpty)
  }

  @Test("Payloads round-trip and reject malformed input")
  func payloadRoundTrip() throws {
    let original = payload()
    let decoded = try SupervisionPayload(userInfo: original.userInfo)
    #expect(decoded == original)
    let update = SupervisionPayload(
      serverURL: server, sessionID: "s", decisionID: nil, kind: .completed)
    #expect(try SupervisionPayload(userInfo: update.userInfo) == update)

    func rejects(_ change: (inout [String: Any]) -> Void) -> Bool {
      var inner = original.userInfo["omnigent"] as? [String: Any] ?? [:]
      change(&inner)
      do {
        _ = try SupervisionPayload(userInfo: ["omnigent": inner])
        return false
      } catch {
        return true
      }
    }
    #expect(rejects { $0["version"] = 2 })
    #expect(rejects { $0["kind"] = "delete" })
    #expect(rejects { $0["session_id"] = "../etc" })
    #expect(rejects { $0["decision_id"] = "a/b" })
    #expect(rejects { $0["session_id"] = String(repeating: "a", count: 300) })
    #expect(rejects { $0["server_url"] = nil })
    #expect(throws: SupervisionError.self) { try SupervisionPayload(userInfo: [:]) }
  }
}

@MainActor
struct SupervisionReplyTests {
  @Test("Replies map to feedback, an option or the one text field")
  func replies() throws {
    #expect(
      try SupervisionReply.response(for: card("a", feedback: true), text: " Use the tests ")
        == .declineWithFeedback(feedback: "Use the tests"))
    let choice = card("c", kind: .choice(answerKey: "k", options: ["Sessions", "Approvals first"]))
    #expect(
      try SupervisionReply.response(for: choice, text: "approvals FIRST")
        == .answer(value: "Approvals first"))
    #expect(try SupervisionReply.response(for: choice, text: "1") == .answer(value: "Sessions"))
    #expect(throws: SupervisionError.replyDoesNotMatch) {
      try SupervisionReply.response(for: choice, text: "3")
    }
    let form = card("f", kind: .form(fields: [field("why")]))
    #expect(
      try SupervisionReply.response(for: form, text: "because")
        == .form(values: ["why": .text(value: "because")]))
    #expect(throws: SupervisionError.emptyReply) {
      try SupervisionReply.response(for: form, text: "  ")
    }
    #expect(throws: SupervisionError.actionNotOffered) {
      try SupervisionReply.response(for: card("a"), text: "no")
    }
  }
}

@MainActor
struct SupervisionActionTests {
  @Test("Approve and Deny re-check the request, then answer it")
  func approveAndDeny() async throws {
    let source = FakeSource()
    source.pending["parent"] = [card("d1"), card("d2")]
    let approved = try await SupervisionActionRouter.perform(
      .approve, text: nil, payload: payload(), source: source)
    #expect(approved == .approve)
    let denied = try await SupervisionActionRouter.perform(
      .deny, text: nil, payload: payload(decision: "d2"), source: source)
    #expect(denied == .decline)
    #expect(source.reads == ["parent", "parent"])
    #expect(source.resolved.map(\.decision) == ["d1", "d2"])
  }

  @Test("A request answered elsewhere is never answered again")
  func staleRequest() async {
    let source = FakeSource()
    source.pending["parent"] = [card("other")]
    await #expect(throws: SupervisionError.requestGone) {
      try await SupervisionActionRouter.perform(
        .approve, text: nil, payload: payload(), source: source)
    }
    source.pending["parent"] = [card("d1", answered: true)]
    await #expect(throws: SupervisionError.requestGone) {
      try await SupervisionActionRouter.perform(
        .approve, text: nil, payload: payload(), source: source)
    }
    #expect(source.resolved.isEmpty)
  }

  @Test("An action the current request doesn't offer is refused")
  func mismatchedAction() async {
    let source = FakeSource()
    // The request is now a question: Approve must not answer it.
    source.pending["parent"] = [card("d1", kind: .choice(answerKey: "k", options: ["a"]))]
    await #expect(throws: SupervisionError.actionNotOffered) {
      try await SupervisionActionRouter.perform(
        .approve, text: nil, payload: payload(), source: source)
    }
    await #expect(throws: SupervisionError.actionNotOffered) {
      try await SupervisionActionRouter.perform(
        .approve, text: nil, payload: payload(decision: nil), source: source)
    }
    #expect(source.resolved.isEmpty)
  }

  @Test("Reply answers a question through the core")
  func reply() async throws {
    let source = FakeSource()
    source.pending["parent"] = [card("d1", kind: .choice(answerKey: "k", options: ["Yes", "No"]))]
    let sent = try await SupervisionActionRouter.perform(
      .reply, text: "no", payload: payload(kind: .question), source: source)
    #expect(sent == .answer(value: "No"))
    #expect(source.resolved.count == 1)
  }

  @Test("Another server's notification, or no sign-in, never acts")
  func wrongServer() async {
    let source = FakeSource()
    source.pending["parent"] = [card("d1")]
    source.supervisedServerURL = "https://other.example.com"
    await #expect(throws: SupervisionError.notConnected) {
      try await SupervisionActionRouter.perform(
        .approve, text: nil, payload: payload(), source: source)
    }
    source.supervisedServerURL = nil
    await #expect(throws: SupervisionError.notConnected) {
      try await SupervisionActionRouter.perform(
        .approve, text: nil, payload: payload(), source: source)
    }
    source.supervisedServerURL = server + "/"
    let sent = try? await SupervisionActionRouter.perform(
      .approve, text: nil, payload: payload(), source: source)
    #expect(sent == .approve)
  }

  @Test("Read failures surface")
  func readFailure() async {
    let source = FakeSource()
    source.readError = .failed("Server responded with HTTP 500")
    await #expect(throws: SupervisionError.failed("Server responded with HTTP 500")) {
      try await SupervisionActionRouter.perform(
        .approve, text: nil, payload: payload(), source: source)
    }
  }
}

@MainActor
struct SupervisionNotifierTests {
  @Test("Each pending request notifies once, and turned-off kinds not at all")
  func ledgerAndToggles() async throws {
    let defaults = try #require(UserDefaults(suiteName: "SupervisionNotifierTests"))
    defaults.removePersistentDomain(forName: "SupervisionNotifierTests")
    let preferences = SupervisionPreferences(defaults: defaults)
    let source = FakeSource()
    source.pending["child"] = [
      card("d1"), card("q1", kind: .choice(answerKey: "k", options: ["a"])),
      card("done", answered: true),
    ]
    var contents = try await SupervisionNotifier.decisions(
      in: "child", openSessionID: "parent", sessionTitle: "Parent", source: source,
      isEnabled: preferences.isEnabled)
    #expect(contents.map(\.payload.decisionID) == ["d1", "q1"])
    var ledger = SupervisionLedger()
    let first = contents.filter { ledger.admit($0) }
    let again = contents.filter { ledger.admit($0) }
    #expect(first.count == 2)
    #expect(again.isEmpty)
    ledger.forget(contents[0])
    let retried = ledger.admit(contents[0])
    #expect(retried)

    preferences.set(.question, enabled: false)
    #expect(!SupervisionPreferences(defaults: defaults).isEnabled(.question))
    contents = try await SupervisionNotifier.decisions(
      in: "child", openSessionID: "parent", sessionTitle: nil, source: source,
      isEnabled: preferences.isEnabled)
    #expect(contents.map(\.payload.decisionID) == ["d1"])
  }

  @Test("The ledger is bounded")
  func ledgerBound() {
    var ledger = SupervisionLedger()
    for index in 0..<(SupervisionLedger.capacity + 10) {
      _ = ledger.admit(
        SupervisionContent.turnEnded(
          .completed, serverURL: server, sessionID: "s\(index)", sessionTitle: nil))
    }
    #expect(ledger.entries.count == SupervisionLedger.capacity)
    #expect(ledger.entries.first?.contains("/c/s10/") == true)
  }
}

@MainActor
struct SupervisionCoreTests {
  @Test("Through the real demo core: re-check, answer, and the request is gone")
  func demoCore() async throws {
    let store = try await PreviewData.connectedDemoStore()
    let server = try #require(store.supervisedServerURL)
    let defaults = try #require(UserDefaults(suiteName: "SupervisionCoreTests"))
    defaults.removePersistentDomain(forName: "SupervisionCoreTests")
    let contents = try await SupervisionNotifier.decisions(
      in: "demo-design", openSessionID: "demo-design", sessionTitle: nil, source: store,
      isEnabled: SupervisionPreferences(defaults: defaults).isEnabled)
    let approval = try #require(contents.first)
    #expect(approval.category == .approval)
    #expect(approval.payload.serverURL == server)
    try await SupervisionActionRouter.perform(
      .approve, text: nil, payload: approval.payload, source: store)
    await #expect(throws: SupervisionError.requestGone) {
      try await SupervisionActionRouter.perform(
        .approve, text: nil, payload: approval.payload, source: store)
    }

    let question = try #require(
      try await SupervisionNotifier.decisions(
        in: "demo-question", openSessionID: "demo-question", sessionTitle: nil, source: store,
        isEnabled: SupervisionPreferences(defaults: defaults).isEnabled
      ).first)
    #expect(question.category == .question)
    let answer = try await SupervisionActionRouter.perform(
      .reply, text: "2", payload: question.payload, source: store)
    #expect(answer == .answer(value: "Approvals first"))
  }
}
