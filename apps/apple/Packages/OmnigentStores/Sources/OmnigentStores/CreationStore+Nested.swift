import Foundation
public import OmnigentCoreFFI

/// The session an Add nested agent create starts beside, and the create's own token.
public struct NestedSource: Equatable, Sendable {
  /// The source session.
  public var sessionID: String
  /// Its host: its sandbox may be reused, and the server's policy always allows it.
  public var hostID: String?
  /// This create's `omnigent.client_create_token`, which ties the provisional row to the row the
  /// server sends.
  public var token: String

  /// Creates a source.
  /// - Parameters:
  ///   - sessionID: The source session.
  ///   - hostID: Its host.
  ///   - token: A fresh token for this create.
  public init(sessionID: String, hostID: String?, token: String) {
    self.sessionID = sessionID
    self.hostID = hostID
    self.token = token
  }

  /// The core's request fields.
  var request: NestedRequest {
    NestedRequest(sourceId: sessionID, sourceHostId: hostID, clientToken: token)
  }
}

extension CreationStore {
  /// Reads the composer's source session fresh, for its title, host, folder and branch.
  /// - Parameter sessionID: The source session.
  /// - Returns: The session, or why it could not be read.
  public func nestedSource(_ sessionID: String) async -> Result<SessionSummary, CoreError> {
    do {
      return .success(try await core.nestedSource(sessionId: sessionID))
    } catch {
      return .failure(coreError(error))
    }
  }

  /// Creates a nested agent beside `source` on `selection`'s host, then sends `firstMessage` as
  /// ``create(_:title:firstMessage:)`` does: the session opens as soon as it exists, and
  /// creation is never repeated.
  /// - Parameters:
  ///   - selection: Host, agent, folder and model; its project is never sent.
  ///   - source: The source session and this create's token.
  ///   - title: The session name; may be empty.
  ///   - firstMessage: The first message; may be empty.
  public func createNested(
    _ selection: CreationSelection, beside source: NestedSource, title: String,
    firstMessage: String
  ) async {
    let request = source.request
    await create(
      firstMessage: firstMessage,
      CreationCalls(
        forMessage: { core in
          try await core.createNestedSession(
            selection: selection, request: request, title: title, firstMessage: firstMessage)
        },
        bare: { core in
          try await core.createNestedSession(
            selection: selection, request: request, title: title, firstMessage: nil)
        },
        andSend: { core in
          try await core.createNestedSessionAndSend(
            selection: selection, request: request, title: title, text: firstMessage)
        }))
  }

  /// Creates a nested agent beside `source` on a new sandbox as `target` describes, then sends
  /// `firstMessage` once it exists, as ``createInSandbox(_:target:title:firstMessage:)`` does.
  /// - Parameters:
  ///   - selection: The agent and run configuration; its host and folder are not used.
  ///   - target: The sandbox.
  ///   - source: The source session and this create's token.
  ///   - title: The session name; may be empty.
  ///   - firstMessage: Sent once the session exists; may be empty.
  public func createNestedInSandbox(
    _ selection: CreationSelection, target: SandboxTarget, beside source: NestedSource,
    title: String, firstMessage: String
  ) async {
    let request = source.request
    await createThenSend(firstMessage: firstMessage) { core in
      let receipt = try await core.createNestedSandboxSession(
        selection: selection, target: target, request: request, title: title)
      return (receipt.sessionId, nil)
    }
  }

  /// A fresh token for one nested create: 32 lowercase hex digits, as the web makes them.
  public static func newCreateToken() -> String {
    UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
  }
}
