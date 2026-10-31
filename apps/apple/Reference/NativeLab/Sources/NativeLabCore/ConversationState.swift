import Foundation

public struct ConversationState: Equatable, Sendable {
  public private(set) var snapshot: ConversationSnapshot

  public init(snapshot: ConversationSnapshot) {
    self.snapshot = snapshot
  }

  @discardableResult
  public mutating func apply(_ incoming: ConversationSnapshot) -> Bool {
    guard incoming.id == snapshot.id, incoming.revision > snapshot.revision else {
      return false
    }
    snapshot = incoming
    return true
  }
}
