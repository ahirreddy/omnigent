import Foundation
public import OmnigentCoreFFI

/// What a supervision notification is about. Each kind has its own toggle in Settings.
nonisolated public enum SupervisionKind: String, CaseIterable, Hashable, Sendable {
  /// An agent asks to approve a tool call or change.
  case approval
  /// An agent asks a question (a choice or a form).
  case question
  /// A turn finished.
  case completed
  /// A turn failed.
  case failed
}

/// A notification category: which actions the notification offers.
nonisolated public enum SupervisionCategory: String, CaseIterable, Hashable, Sendable {
  /// Approve and Deny.
  case approval = "omnigent.approval"
  /// Approve, Deny and Reply, where Reply declines with feedback for the agent.
  case approvalWithReply = "omnigent.approval.reply"
  /// Reply, for a choice or a one-field text form.
  case question = "omnigent.question"
  /// No actions; tapping opens the session.
  case update = "omnigent.update"

  /// The actions, in the order they show.
  public var actions: [SupervisionAction] {
    switch self {
    case .approval: [.approve, .deny]
    case .approvalWithReply: [.approve, .deny, .reply]
    case .question: [.reply]
    case .update: []
    }
  }

  /// The category for `card`: what the notification can answer without opening the app.
  /// - Parameter card: The pending decision.
  /// - Returns: The category.
  public static func of(_ card: DecisionCard) -> Self {
    switch card.kind {
    case .approval:
      return card.acceptsFeedback ? .approvalWithReply : .approval
    case .choice:
      return .question
    case .form(let fields):
      return SupervisionReply.singleTextField(fields) == nil ? .update : .question
    case .unsupported:
      return .update
    }
  }
}

/// A notification action button.
nonisolated public enum SupervisionAction: String, CaseIterable, Hashable, Sendable {
  /// Approve. The system requires device authentication first.
  case approve = "omnigent.approve"
  /// Deny.
  case deny = "omnigent.deny"
  /// Reply with text.
  case reply = "omnigent.reply"
}

/// What a supervision notification carries in `userInfo["omnigent"]`. Identifiers only: never a
/// command, path, message or URL to navigate to. The shape follows the push payload in
/// `docs/phone-supervision.md`, so local and remote notifications decode the same way.
nonisolated public struct SupervisionPayload: Hashable, Sendable {
  /// The `userInfo` key.
  public static let userInfoKey = "omnigent"
  /// The only version this client reads.
  public static let version = 1
  /// Longest identifier accepted.
  static let maximumIdentifierLength = 256

  /// The canonical server URL the request belongs to.
  public var serverURL: String
  /// The session the decision is resolved through (it carries the card).
  public var sessionID: String
  /// The session a tap opens: the parent, for a sub-agent's request.
  public var openSessionID: String
  /// The pending decision, for an actionable notification.
  public var decisionID: String?
  /// What happened.
  public var kind: SupervisionKind

  /// Creates a payload.
  /// - Parameters:
  ///   - serverURL: The canonical server URL.
  ///   - sessionID: The session carrying the decision.
  ///   - openSessionID: The session to open on tap; `sessionID` when `nil`.
  ///   - decisionID: The decision, when there is one.
  ///   - kind: What happened.
  public init(
    serverURL: String, sessionID: String, openSessionID: String? = nil, decisionID: String?,
    kind: SupervisionKind
  ) {
    self.serverURL = serverURL
    self.sessionID = sessionID
    self.openSessionID = openSessionID ?? sessionID
    self.decisionID = decisionID
    self.kind = kind
  }

  /// The `userInfo` dictionary.
  public var userInfo: [String: any Sendable] {
    var payload: [String: any Sendable] = [
      "version": Self.version, "server_url": serverURL, "session_id": sessionID,
      "open_session_id": openSessionID, "kind": kind.rawValue,
    ]
    if let decisionID { payload["decision_id"] = decisionID }
    return [Self.userInfoKey: payload]
  }

  /// The payload as strings, for the Mac's notification center, which hands them back with
  /// the chosen action.
  public var context: [String: String] {
    var context = [
      "server_url": serverURL, "session_id": sessionID, "open_session_id": openSessionID,
      "kind": kind.rawValue,
    ]
    context["decision_id"] = decisionID
    return context
  }

  /// Reads ``context``.
  /// - Parameter context: The strings.
  /// - Throws: ``SupervisionError/malformedPayload(_:)``.
  public init(context: [String: String]) throws(SupervisionError) {
    var payload: [String: Any] = context
    payload["version"] = Self.version
    try self.init(userInfo: [Self.userInfoKey: payload])
  }

  /// Reads a payload written by ``userInfo`` or sent by a server.
  /// - Parameter userInfo: The notification's `userInfo`.
  /// - Throws: ``SupervisionError/malformedPayload(_:)`` naming the first problem.
  public init(userInfo: [AnyHashable: Any]) throws(SupervisionError) {
    guard let payload = userInfo[Self.userInfoKey] as? [String: Any] else {
      throw .malformedPayload("no omnigent payload")
    }
    guard payload["version"] as? Int == Self.version else {
      throw .malformedPayload("unsupported version")
    }
    guard let serverURL = payload["server_url"] as? String, URL(string: serverURL) != nil else {
      throw .malformedPayload("no server_url")
    }
    guard let rawKind = payload["kind"] as? String, let kind = SupervisionKind(rawValue: rawKind)
    else { throw .malformedPayload("unknown kind") }
    let sessionID = try Self.identifier(payload["session_id"], field: "session_id")
    var openSessionID: String?
    if let value = payload["open_session_id"] {
      openSessionID = try Self.identifier(value, field: "open_session_id")
    }
    var decisionID: String?
    if let value = payload["decision_id"] {
      decisionID = try Self.identifier(value, field: "decision_id")
    }
    self.init(
      serverURL: serverURL, sessionID: sessionID, openSessionID: openSessionID,
      decisionID: decisionID, kind: kind)
  }

  private static func identifier(_ value: Any?, field: String) throws(SupervisionError) -> String {
    guard let value = value as? String, !value.isEmpty, value.count <= maximumIdentifierLength,
      value.unicodeScalars.allSatisfy(isIdentifierScalar)
    else { throw .malformedPayload("invalid \(field)") }
    return value
  }

  private static func isIdentifierScalar(_ scalar: Unicode.Scalar) -> Bool {
    scalar.isASCII
      && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_")
  }
}

/// What a supervision notification shows. Titles only: the session's title and a fixed line
/// per kind, never the request's text, tool input, command or paths.
nonisolated public struct SupervisionContent: Hashable, Sendable {
  /// Longest title shown.
  static let maximumTitleLength = 80

  /// Request identifier; a newer notification for the same request replaces the older one. A
  /// decision's is the same whether it was read from the sub-agent or its parent.
  public var identifier: String
  /// Groups a session's notifications (a sub-agent's go with its parent).
  public var threadIdentifier: String
  /// The session title.
  public var title: String
  /// A fixed line for the kind.
  public var body: String
  /// The actions offered.
  public var category: SupervisionCategory
  /// Routing identifiers.
  public var payload: SupervisionPayload

  /// The notification for one pending decision.
  /// - Parameters:
  ///   - card: The decision, read fresh from the core.
  ///   - serverURL: The canonical server URL.
  ///   - sessionID: The session the card was read from.
  ///   - openSessionID: The session a tap opens (the parent of a sub-agent).
  ///   - sessionTitle: The title of `openSessionID`, when known.
  /// - Returns: The content.
  public static func decision(
    _ card: DecisionCard, serverURL: String, sessionID: String, openSessionID: String,
    sessionTitle: String?
  ) -> Self {
    let category = SupervisionCategory.of(card)
    let kind: SupervisionKind = if case .approval = card.kind { .approval } else { .question }
    let body =
      switch category {
      case .approval, .approvalWithReply: "Waiting for your approval"
      case .question: "Has a question for you"
      case .update: "Needs your input in Omnigent"
      }
    return Self(
      identifier: "\(serverURL)/d/\(card.id)",
      threadIdentifier: thread(serverURL: serverURL, sessionID: openSessionID),
      title: title(sessionTitle), body: body, category: category,
      payload: SupervisionPayload(
        serverURL: serverURL, sessionID: sessionID, openSessionID: openSessionID,
        decisionID: card.id, kind: kind))
  }

  /// The notification for a turn that finished or failed.
  /// - Parameters:
  ///   - kind: ``SupervisionKind/completed`` or ``SupervisionKind/failed``.
  ///   - serverURL: The canonical server URL.
  ///   - sessionID: The session (the parent, for a rolled-up sub-agent).
  ///   - sessionTitle: Its title, when known.
  /// - Returns: The content.
  public static func turnEnded(
    _ kind: SupervisionKind, serverURL: String, sessionID: String, sessionTitle: String?
  ) -> Self {
    Self(
      identifier: "\(serverURL)/c/\(sessionID)/turn",
      threadIdentifier: thread(serverURL: serverURL, sessionID: sessionID),
      title: title(sessionTitle),
      body: kind == .failed ? "Stopped with an error" : "Finished and ready for you",
      category: .update,
      payload: SupervisionPayload(
        serverURL: serverURL, sessionID: sessionID, decisionID: nil, kind: kind))
  }

  /// Tells the user an action from a notification did not happen.
  /// - Parameters:
  ///   - error: Why.
  ///   - payload: The notification acted on.
  ///   - sessionTitle: Its session's title, when known.
  /// - Returns: The content.
  public static func failure(
    _ error: SupervisionError, payload: SupervisionPayload, sessionTitle: String?
  ) -> Self {
    Self(
      identifier: "\(payload.serverURL)/c/\(payload.sessionID)/failure",
      threadIdentifier: thread(serverURL: payload.serverURL, sessionID: payload.openSessionID),
      title: title(sessionTitle), body: error.message, category: .update,
      payload: SupervisionPayload(
        serverURL: payload.serverURL, sessionID: payload.sessionID,
        openSessionID: payload.openSessionID, decisionID: nil, kind: payload.kind))
  }

  static func thread(serverURL: String, sessionID: String) -> String {
    "\(serverURL)/c/\(sessionID)"
  }

  static func title(_ sessionTitle: String?) -> String {
    let trimmed = sessionTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmed.isEmpty else { return "Omnigent" }
    guard trimmed.count > maximumTitleLength else { return trimmed }
    return String(trimmed.prefix(maximumTitleLength - 1)) + "\u{2026}"
  }
}

/// Why a notification action or a supervision notification failed.
nonisolated public enum SupervisionError: Error, Hashable, Sendable {
  /// The notification's payload is not one this client reads.
  case malformedPayload(String)
  /// No signed-in connection to the notification's server.
  case notConnected
  /// The request was answered or withdrawn since the notification was shown.
  case requestGone
  /// The action does not fit the request (for example Approve on a question).
  case actionNotOffered
  /// An empty reply.
  case emptyReply
  /// The reply matches none of the request's options.
  case replyDoesNotMatch
  /// The request needs the app to answer.
  case needsApp
  /// Device authentication failed or was cancelled.
  case authenticationFailed
  /// The core or the server refused; the message is for display.
  case failed(String)

  /// For display in a follow-up notification. Never includes the request's text.
  public var message: String {
    switch self {
    case .malformedPayload: "This notification can't be answered. Open Omnigent instead."
    case .notConnected: "Not signed in to this server. Open Omnigent to answer."
    case .requestGone: "This request was already answered."
    case .actionNotOffered, .needsApp: "Open Omnigent to answer this request."
    case .emptyReply: "The reply was empty. Open Omnigent to answer."
    case .replyDoesNotMatch: "The reply didn't match an option. Open Omnigent to answer."
    case .authenticationFailed: "Not approved: authentication failed."
    case .failed(let message): "Couldn't answer: \(message)"
    }
  }
}

/// Turns a text reply into a decision answer.
nonisolated public enum SupervisionReply {
  /// The answer for `text` on `card`: feedback on an approval that takes it, an option of a
  /// choice (by its text, ignoring case, or its 1-based number), or the one field of a text
  /// form.
  /// - Parameters:
  ///   - card: The pending decision.
  ///   - text: What the user typed.
  /// - Returns: The answer.
  /// - Throws: ``SupervisionError`` when the text can't answer the card.
  public static func response(for card: DecisionCard, text: String) throws(SupervisionError)
    -> DecisionResponse
  {
    let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !reply.isEmpty else { throw .emptyReply }
    switch card.kind {
    case .approval:
      guard card.acceptsFeedback else { throw .actionNotOffered }
      return .declineWithFeedback(feedback: reply)
    case .choice(_, let options):
      if let option = options.first(where: {
        $0.compare(reply, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
      }) {
        return .answer(value: option)
      }
      if let number = Int(reply), options.indices.contains(number - 1) {
        return .answer(value: options[number - 1])
      }
      throw .replyDoesNotMatch
    case .form(let fields):
      guard let field = singleTextField(fields) else { throw .needsApp }
      return .form(values: [field.key: .text(value: reply)])
    case .unsupported:
      throw .needsApp
    }
  }

  /// The form's only field when it takes free, non-secret text.
  static func singleTextField(_ fields: [FormField]) -> FormField? {
    guard fields.count == 1, let field = fields.first, field.kind == .text, !field.isSecret
    else { return nil }
    return field
  }
}
