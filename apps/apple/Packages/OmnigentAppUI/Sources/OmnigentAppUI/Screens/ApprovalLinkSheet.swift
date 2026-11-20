import Foundation
import Observation
import OmnigentCoreFFI
public import OmnigentDeepLinks
import OmnigentStores
import OmnigentUIComponents
import SwiftUI

/// An approval link to show: `…/approve/<session>/<request>`, the page a policy's URL-mode
/// approval names.
public struct ApprovalLinkRequest: Identifiable, Hashable, Sendable {
  /// The session the request belongs to.
  public let sessionID: String
  /// The request (elicitation) id.
  public let elicitationID: String

  /// The request's identity.
  public var id: String { "\(sessionID)/\(elicitationID)" }

  /// Creates a request.
  public init(sessionID: String, elicitationID: String) {
    self.sessionID = sessionID
    self.elicitationID = elicitationID
  }

  /// The request an approval link's route names; `nil` for any other route.
  public init?(_ route: OmnigentDeepLinks.DeepLinkRoute) {
    guard case .approval(let sessionID, let elicitationID) = route else { return nil }
    self.init(sessionID: sessionID, elicitationID: elicitationID)
  }
}

/// Reads one approval link's request fresh from the server and answers it, as the web's approve
/// page: pending (the chat's own card), resolved, answered, or the read's failure.
@MainActor @Observable
final class ApprovalLinkModel {
  private(set) var state = ApprovalLinkState.loading
  private let request: ApprovalLinkRequest
  private let source: any SupervisionDecisionSource

  init(request: ApprovalLinkRequest, source: any SupervisionDecisionSource) {
    self.request = request
    self.source = source
  }

  /// Reads the request: pending while the session still waits on it, else resolved.
  func load() async {
    do throws(SupervisionError) {
      state = try await current().map { .pending($0, .pending) } ?? .resolved
    } catch {
      state = .failed(error.message)
    }
  }

  /// Answers the request. A verdict the agent's terminal hasn't confirmed brings the card back
  /// to send again, as the chat's card does; otherwise the answer shows as approved or rejected.
  func respond(_ response: OmnigentUIComponents.DecisionResponse) async {
    guard case .pending(let card, _) = state else { return }
    state = .pending(card, .resolving)
    do throws(SupervisionError) {
      try await source.resolve(
        sessionID: request.sessionID, decisionID: request.elicitationID,
        response: OmnigentCoreFFI.DecisionResponse(response))
      if let again = try await current(), again.permissions.nativeDelivery?.state == .unconfirmed {
        state = .pending(again, .pending)
      } else {
        state = .submitted(approved: Self.approves(response))
      }
    } catch {
      state = .pending(card, .failed(message: error.message))
    }
  }

  private func current() async throws(SupervisionError) -> OmnigentUIComponents.DecisionCard? {
    let cards = try await source.pendingDecisions(sessionID: request.sessionID)
    return cards.first { $0.id == request.elicitationID && !$0.answered }
      .map { OmnigentUIComponents.DecisionCard($0) }
  }

  /// Whether `response` accepts the request ("Approved") rather than declining it ("Rejected").
  static func approves(_ response: OmnigentUIComponents.DecisionResponse) -> Bool {
    switch response {
    case .decline, .cancel, .declineWithFeedback: false
    default: true
    }
  }
}

/// Shows ``ServerSession/approvalLink`` as a sheet over the window.
struct ApprovalLinkPresentation: ViewModifier {
  let session: ServerSession
  let openSession: @MainActor (String) -> Void

  func body(content: Content) -> some View {
    content.sheet(
      item: Binding(get: { session.approvalLink }, set: { session.approvalLink = $0 })
    ) { request in
      ApprovalLinkSheet(
        model: ApprovalLinkModel(request: request, source: session.connection),
        openSession: {
          session.approvalLink = nil
          openSession(request.sessionID)
        },
        done: { session.approvalLink = nil })
    }
  }
}

/// The sheet: the request read once it opens.
private struct ApprovalLinkSheet: View {
  @State private var model: ApprovalLinkModel
  let openSession: @MainActor () -> Void
  let done: @MainActor () -> Void

  init(
    model: ApprovalLinkModel, openSession: @escaping @MainActor () -> Void,
    done: @escaping @MainActor () -> Void
  ) {
    _model = State(initialValue: model)
    self.openSession = openSession
    self.done = done
  }

  var body: some View {
    ApprovalLinkView(
      state: model.state, respond: { response in Task { await model.respond(response) } },
      openSession: openSession, done: done
    )
    .task { await model.load() }
  }
}
