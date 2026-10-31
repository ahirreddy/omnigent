import Foundation

/// Domain operations for the test app. A live adapter must translate server wire contracts.
public protocol SessionClient: Sendable {
  func sessions() async throws -> [SessionSummary]
  func conversation(id: String) async throws -> ConversationSnapshot
  func updates() async -> AsyncStream<ConversationSnapshot>
  func send(_ text: String, to sessionID: String) async throws
  func interrupt(sessionID: String) async throws
  func resolve(
    decisionID: String, sessionID: String, response: DecisionResponse
  ) async throws
  func createSession(title: String) async throws -> ConversationSnapshot
  func editSession(_ sessionID: String, change: SessionChange) async throws
}

public enum SessionChange: Equatable, Sendable {
  case title(String)
  case pinned(Bool)
  case archived(Bool)
}
