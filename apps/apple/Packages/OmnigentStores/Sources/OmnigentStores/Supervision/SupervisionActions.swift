public import Foundation
public import Observation
public import OmnigentCoreFFI

/// The core calls supervision needs: the decisions a session waits on now, and answering one.
/// ``ConnectionStore`` is the production source; tests use a fake.
public protocol SupervisionDecisionSource: AnyObject {
  /// The canonical URL of the signed-in server, or `nil` when not signed in.
  var supervisedServerURL: String? { get }
  /// The decisions `sessionID` waits on now, read fresh from the server.
  /// - Parameter sessionID: The session.
  /// - Returns: The pending cards.
  /// - Throws: ``SupervisionError``.
  func pendingDecisions(sessionID: String) async throws(SupervisionError) -> [DecisionCard]
  /// Answers `decisionID` through `sessionID`.
  /// - Parameters:
  ///   - sessionID: The session carrying the card.
  ///   - decisionID: The decision.
  ///   - response: The answer.
  /// - Throws: ``SupervisionError``.
  func resolve(sessionID: String, decisionID: String, response: DecisionResponse)
    async throws(SupervisionError)
}

/// Runs a notification's Approve, Deny or Reply. Before answering, it re-reads the session's
/// pending decisions through the core and acts only when the notified request is still pending
/// and still the kind of request the notification offered actions for. The core checks once more
/// before it writes.
public enum SupervisionActionRouter {
  /// Performs `action` on the request `payload` names.
  /// - Parameters:
  ///   - action: The button.
  ///   - text: The typed reply, for ``SupervisionAction/reply``.
  ///   - payload: The notification's payload.
  ///   - source: The connection to the payload's server.
  /// - Returns: The answer that was sent.
  /// - Throws: ``SupervisionError``; nothing was sent.
  @discardableResult
  public static func perform(
    _ action: SupervisionAction, text: String?, payload: SupervisionPayload,
    source: any SupervisionDecisionSource
  ) async throws(SupervisionError) -> DecisionResponse {
    guard let decisionID = payload.decisionID else { throw .actionNotOffered }
    guard let server = source.supervisedServerURL else { throw .notConnected }
    guard ServerURLMatch.same(server, payload.serverURL) else { throw .notConnected }
    let cards = try await source.pendingDecisions(sessionID: payload.sessionID)
    guard let card = cards.first(where: { $0.id == decisionID && !$0.answered }) else {
      throw .requestGone
    }
    guard SupervisionCategory.of(card).actions.contains(action) else { throw .actionNotOffered }
    let response = try response(for: action, card: card, text: text)
    try await source.resolve(
      sessionID: payload.sessionID, decisionID: decisionID, response: response)
    return response
  }

  static func response(for action: SupervisionAction, card: DecisionCard, text: String?)
    throws(SupervisionError) -> DecisionResponse
  {
    switch action {
    case .approve: return .approve
    case .deny: return .decline
    case .reply: return try SupervisionReply.response(for: card, text: text ?? "")
    }
  }
}

/// Compares server URLs the way notifications store them.
nonisolated enum ServerURLMatch {
  static func same(_ lhs: String, _ rhs: String) -> Bool {
    normalized(lhs) == normalized(rhs)
  }

  private static func normalized(_ url: String) -> String {
    var value = url.lowercased()
    while value.hasSuffix("/") { value.removeLast() }
    return value
  }
}

/// Requests already notified, so the live path and the background poll each notify a request
/// once. Bounded; the oldest entries go first.
nonisolated public struct SupervisionLedger: Hashable, Sendable {
  /// Most entries kept.
  public static let capacity = 512
  /// Entries, oldest first.
  public private(set) var entries: [String]

  /// Creates a ledger.
  /// - Parameter entries: Saved entries, oldest first.
  public init(entries: [String] = []) {
    self.entries = Array(entries.suffix(Self.capacity))
  }

  /// Records `content` and reports whether it is new.
  /// - Parameter content: The notification about to be posted.
  /// - Returns: `false` when it was already notified.
  public mutating func admit(_ content: SupervisionContent) -> Bool {
    let key = content.identifier
    guard !entries.contains(key) else { return false }
    entries.append(key)
    if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
    return true
  }

  /// Forgets `content`, for example after a failed post, so a later pass tries again.
  /// - Parameter content: The notification.
  public mutating func forget(_ content: SupervisionContent) {
    entries.removeAll { $0 == content.identifier }
  }
}

/// Which supervision notifications the user wants (Settings › Notifications on iPhone and iPad).
@Observable
public final class SupervisionPreferences {
  static let prefix = "omnigent.supervision.notify."

  @ObservationIgnored private let defaults: UserDefaults
  private var enabled: [SupervisionKind: Bool]

  /// Reads the preferences. Every kind is on by default.
  /// - Parameter defaults: Where they are kept.
  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    var enabled: [SupervisionKind: Bool] = [:]
    for kind in SupervisionKind.allCases {
      enabled[kind] = defaults.object(forKey: Self.prefix + kind.rawValue) as? Bool ?? true
    }
    self.enabled = enabled
  }

  /// Whether `kind` notifies.
  /// - Parameter kind: The kind.
  /// - Returns: Whether it is on.
  public func isEnabled(_ kind: SupervisionKind) -> Bool {
    enabled[kind] ?? true
  }

  /// Turns `kind` on or off.
  /// - Parameters:
  ///   - kind: The kind.
  ///   - isEnabled: Whether it notifies.
  public func set(_ kind: SupervisionKind, enabled isEnabled: Bool) {
    enabled[kind] = isEnabled
    defaults.set(isEnabled, forKey: Self.prefix + kind.rawValue)
  }
}

/// Builds the notifications for what needs the user on one server.
public enum SupervisionNotifier {
  /// One notification per request `sessionID` waits on, read fresh through the core, minus
  /// the kinds the user turned off.
  /// - Parameters:
  ///   - sessionID: The session to read (a sub-agent's or its parent's).
  ///   - openSessionID: The session a tap opens; its title is the notification's title.
  ///   - sessionTitle: That title, when known.
  ///   - source: The connection.
  ///   - isEnabled: Whether the user wants a kind (``SupervisionPreferences/isEnabled(_:)``).
  /// - Returns: The contents, in the server's order.
  /// - Throws: ``SupervisionError`` when the read fails.
  public static func decisions(
    in sessionID: String, openSessionID: String, sessionTitle: String?,
    source: any SupervisionDecisionSource, isEnabled: (SupervisionKind) -> Bool
  ) async throws(SupervisionError) -> [SupervisionContent] {
    guard let server = source.supervisedServerURL else { throw .notConnected }
    let cards = try await source.pendingDecisions(sessionID: sessionID)
    return cards.filter { !$0.answered }.map {
      SupervisionContent.decision(
        $0, serverURL: server, sessionID: sessionID, openSessionID: openSessionID,
        sessionTitle: sessionTitle)
    }
    .filter { isEnabled($0.payload.kind) }
  }
}

extension ConnectionStore: SupervisionDecisionSource {
  /// The canonical URL of the server: the signed-in one, or the discovered one while the
  /// phase catches up (the core still refuses calls that need a sign-in).
  public var supervisedServerURL: String? { connectedServer?.baseUrl ?? discovery?.baseUrl }

  /// The decisions `sessionID` waits on now, through the core.
  /// - Parameter sessionID: The session.
  /// - Returns: The pending cards.
  /// - Throws: ``SupervisionError``.
  public func pendingDecisions(sessionID: String) async throws(SupervisionError)
    -> [DecisionCard]
  {
    // The core reports a connection that is not signed in as `notConnected`.
    guard let core else { throw .notConnected }
    do {
      return try await core.pendingDecisions(sessionId: sessionID)
    } catch {
      throw Self.supervisionError(error)
    }
  }

  /// Answers `decisionID` through the core, which re-checks it first.
  /// - Parameters:
  ///   - sessionID: The session carrying the card.
  ///   - decisionID: The decision.
  ///   - response: The answer.
  /// - Throws: ``SupervisionError``.
  public func resolve(sessionID: String, decisionID: String, response: DecisionResponse)
    async throws(SupervisionError)
  {
    // The core reports a connection that is not signed in as `notConnected`.
    guard let core else { throw .notConnected }
    do {
      try await core.resolveDecision(
        sessionId: sessionID, decisionId: decisionID, response: response)
    } catch {
      throw Self.supervisionError(error)
    }
  }

  static func supervisionError(_ error: any Error) -> SupervisionError {
    let error = coreError(error)
    if error.requiresSignIn { return .notConnected }
    if case .Session(.notConnected, _, _, _, _) = error { return .notConnected }
    return .failed(error.message)
  }
}
