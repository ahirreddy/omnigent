public import Observation
public import OmnigentCoreFFI

/// The decision cards of one conversation. A pending card is never hidden.
@Observable
public final class DecisionStore {
  /// Every card, pending or locally answered.
  public private(set) var cards: [DecisionCard] = []
  /// Answers given here, by card id. One stays from the tap until the server retires its card,
  /// so the card shows the answer and never reads as pending in between.
  public private(set) var answers: [String: DecisionResponse] = [:]
  /// The last failed answer, by card id.
  public private(set) var errors: [String: CoreError] = [:]
  /// The native delivery attempt each answer went out for, by card id.
  private var answeredAttempts: [String: String] = [:]

  private let sessionID: String
  private let core: ClientCore
  private let listStatus: ListStatusExpectation

  init(
    sessionID: String, core: ClientCore,
    listStatus: ListStatusExpectation = ListStatusExpectation()
  ) {
    self.sessionID = sessionID
    self.core = core
    self.listStatus = listStatus
  }

  /// Cards the user has not answered.
  public var pending: [DecisionCard] { cards.filter { !$0.answered && answers[$0.id] == nil } }

  /// Sends `response` for `card`, once. The answer shows at once (``answers``) and stays until
  /// the server retires the card; answering the last pending card also shows the session
  /// running in the list. A failure takes both back and is kept in ``errors``.
  /// - Parameters:
  ///   - card: The card.
  ///   - response: The answer.
  public func resolve(_ card: DecisionCard, with response: DecisionResponse) async {
    guard answers[card.id] == nil else { return }
    let othersPending = pending.contains { $0.id != card.id }
    answers[card.id] = response
    answeredAttempts[card.id] = card.permissions.nativeDelivery?.attempt
    errors[card.id] = nil
    let expectation = othersPending ? nil : listStatus.expect(.running)
    do {
      try await core.resolveDecision(
        sessionId: sessionID, decisionId: card.id, response: response)
    } catch {
      expectation?.withdraw()
      // The card may have retired while the answer was out; then there is nothing to take back.
      if answers[card.id] != nil { answers[card.id] = nil }
      errors[card.id] = coreError(error)
    }
  }

  func replace(_ cards: [DecisionCard]) {
    self.cards = cards
    let ids = Set(cards.map(\.id))
    errors = errors.filter { ids.contains($0.key) }
    for id in answers.keys where !ids.contains(id) {
      answers[id] = nil
    }
    // A verdict the agent's terminal never confirmed comes back under a new attempt; the card
    // reopens so it can be sent again.
    for card in cards where answers[card.id] != nil {
      guard let delivery = card.permissions.nativeDelivery, delivery.state == .unconfirmed,
        delivery.attempt != answeredAttempts[card.id]
      else { continue }
      answers[card.id] = nil
    }
    answeredAttempts = answeredAttempts.filter { answers[$0.key] != nil }
  }
}
