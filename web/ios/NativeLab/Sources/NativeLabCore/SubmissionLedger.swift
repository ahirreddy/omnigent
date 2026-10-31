import Foundation

/// Delivery state belongs to a server/account/session, not a view or connection generation.
public struct SubmissionLedger: Sendable {
  public struct Operation: Equatable, Sendable {
    public let id: UUID
    public let scope: String
    public let sessionID: String
    public let draft: String
  }

  public enum Outcome: Sendable {
    case accepted
    case rejected
    case uncertain
  }

  public struct Resolution: Equatable, Sendable {
    public let draft: String
    public let isUncertain: Bool
  }

  private struct Key: Hashable, Sendable {
    let scope: String
    let sessionID: String
  }

  private var pending: [Key: Operation] = [:]
  private var uncertain: Set<Key> = []

  public init() {}

  public mutating func begin(scope: String, sessionID: String, draft: String) -> Operation? {
    let key = Key(scope: scope, sessionID: sessionID)
    guard pending[key] == nil, !uncertain.contains(key) else { return nil }
    let operation = Operation(id: UUID(), scope: scope, sessionID: sessionID, draft: draft)
    pending[key] = operation
    return operation
  }

  public mutating func complete(
    _ operation: Operation, outcome: Outcome, currentDraft: String
  ) -> Resolution? {
    let key = Key(scope: operation.scope, sessionID: operation.sessionID)
    guard pending[key] == operation else { return nil }
    pending[key] = nil
    if case .uncertain = outcome { uncertain.insert(key) }
    let draft: String
    if case .accepted = outcome, currentDraft == operation.draft {
      draft = ""
    } else {
      draft = currentDraft
    }
    return Resolution(draft: draft, isUncertain: uncertain.contains(key))
  }

  public func pendingSessionIDs(in scope: String) -> Set<String> {
    Set(pending.keys.filter { $0.scope == scope }.map(\.sessionID))
  }

  public func uncertainSessionIDs(in scope: String) -> Set<String> {
    Set(uncertain.filter { $0.scope == scope }.map(\.sessionID))
  }

  public mutating func acknowledgeUncertainty(scope: String, sessionID: String) {
    uncertain.remove(Key(scope: scope, sessionID: sessionID))
  }
}
