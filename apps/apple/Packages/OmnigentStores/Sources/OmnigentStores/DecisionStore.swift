public import Observation
public import OmnigentCoreFFI

/// The decision cards of one conversation. A pending card is never hidden.
@Observable
public final class DecisionStore {
  /// Every card, pending or locally answered.
  public private(set) var cards: [DecisionCard] = []
  /// Cards whose answer is being sent.
  public private(set) var resolving: Set<String> = []
  /// The last failed answer, by card id.
  public private(set) var errors: [String: CoreError] = [:]

  private let sessionID: String
  private let core: ClientCore

  init(sessionID: String, core: ClientCore) {
    self.sessionID = sessionID
    self.core = core
  }

  /// Cards the user has not answered.
  public var pending: [DecisionCard] { cards.filter { !$0.answered } }

  /// Sends `response` for `card` on the dedicated resolve route. The card retires when the
  /// server confirms; a failure is kept in ``errors``.
  /// - Parameters:
  ///   - card: The card.
  ///   - response: The answer.
  public func resolve(_ card: DecisionCard, with response: DecisionResponse) async {
    resolving.insert(card.id)
    errors[card.id] = nil
    defer { resolving.remove(card.id) }
    do {
      try await core.resolveDecision(
        sessionId: sessionID, decisionId: card.id, response: response)
    } catch {
      errors[card.id] = coreError(error)
    }
  }

  func replace(_ cards: [DecisionCard]) {
    self.cards = cards
    let ids = Set(cards.map(\.id))
    errors = errors.filter { ids.contains($0.key) }
  }
}
