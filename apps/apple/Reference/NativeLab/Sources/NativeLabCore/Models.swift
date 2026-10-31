import Foundation

public enum SessionStatus: String, Codable, Equatable, Sendable {
  case idle
  case running
  case needsResponse
}

public struct SessionSummary: Identifiable, Codable, Equatable, Sendable {
  public let id: String
  public var title: String
  public var preview: String
  public var status: SessionStatus
  public var isReadOnly: Bool
  public var updatedAt: Date
  public var workspace: String
  public var agentName: String
  public var isPinned: Bool
  public var isArchived: Bool
  public var permissionLevel: Int?
  public var failureMessage: String?
  public var configuration: SessionConfiguration?
  public var configurationRevision: UInt64?

  public var canRename: Bool { permissionLevel.map { $0 >= 2 } ?? !isReadOnly }
  public var canPin: Bool { permissionLevel.map { $0 >= 1 } ?? !isReadOnly }
  public var canArchive: Bool { permissionLevel.map { $0 >= 4 } ?? !isReadOnly }

  /// Keep newer session metadata while the caller merges transcript content independently.
  public func preservingNewerMetadata(from current: SessionSummary?) -> SessionSummary {
    guard let current, current.id == id, let latest = current.configurationRevision else {
      return self
    }
    guard let incoming = configurationRevision, incoming >= latest else { return current }
    return self
  }

  public init(
    id: String, title: String, preview: String, status: SessionStatus = .idle,
    isReadOnly: Bool = false, updatedAt: Date = Date(), workspace: String = "Omni mobile",
    agentName: String = "Omni", isPinned: Bool = false, isArchived: Bool = false,
    permissionLevel: Int? = nil, failureMessage: String? = nil,
    configuration: SessionConfiguration? = nil,
    configurationRevision: UInt64? = nil
  ) {
    self.id = id
    self.title = title
    self.preview = preview
    self.status = status
    self.isReadOnly = isReadOnly
    self.updatedAt = updatedAt
    self.workspace = workspace
    self.agentName = agentName
    self.isPinned = isPinned
    self.isArchived = isArchived
    self.permissionLevel = permissionLevel
    self.failureMessage = failureMessage
    self.configuration = configuration
    self.configurationRevision = configurationRevision
  }
}

public enum MessageRole: String, Codable, Equatable, Sendable {
  case user
  case assistant
  case tool
}

public struct ConversationMessage: Identifiable, Codable, Equatable, Sendable {
  public let id: String
  public let role: MessageRole
  public var text: String
  public var isStreaming: Bool
  public var activity: ConversationActivity?
  public var attachments: [ConversationAttachment]?
  public var callID: String?
  public var responseID: String?
  public var interrupted: Bool?
  public var author: String?
  public var agent: String?

  public init(
    id: String, role: MessageRole, text: String, isStreaming: Bool = false,
    activity: ConversationActivity? = nil, attachments: [ConversationAttachment]? = nil,
    callID: String? = nil, responseID: String? = nil, interrupted: Bool? = nil,
    author: String? = nil, agent: String? = nil
  ) {
    self.id = id
    self.role = role
    self.text = text
    self.isStreaming = isStreaming
    self.activity = activity
    self.attachments = attachments
    self.callID = callID
    self.responseID = responseID
    self.interrupted = interrupted
    self.author = author
    self.agent = agent
  }
}

public enum DecisionResponse: Codable, Equatable, Sendable {
  case approve
  case decline
  case answer(String)
  case form([String: DecisionValue])
  case approveAllEdits
  case approveRemembering
  case approveCommandPolicy([String])
  case declineWithFeedback(String)
}

public struct DecisionRequest: Identifiable, Codable, Equatable, Sendable {
  public let id: String
  public let targetSessionID: String
  public let title: String
  public let detail: String
  public let options: [String]
  public var response: DecisionResponse?
  public let answerKey: String?
  public let unsupportedReason: String?
  public let form: DecisionForm?
  public let externalURL: String?
  public let allowAllEdits: Bool?
  public let rememberLabel: String?
  public let isPlanReview: Bool?
  public let execPolicyAmendment: [String]?

  public init(
    id: String, targetSessionID: String, title: String, detail: String,
    options: [String] = [], response: DecisionResponse? = nil,
    answerKey: String? = nil, unsupportedReason: String? = nil,
    form: DecisionForm? = nil, externalURL: String? = nil,
    allowAllEdits: Bool? = nil, rememberLabel: String? = nil, isPlanReview: Bool? = nil,
    execPolicyAmendment: [String]? = nil
  ) {
    self.id = id
    self.targetSessionID = targetSessionID
    self.title = title
    self.detail = detail
    self.options = options
    self.response = response
    self.answerKey = answerKey
    self.unsupportedReason = unsupportedReason
    self.form = form
    self.externalURL = externalURL
    self.allowAllEdits = allowAllEdits
    self.rememberLabel = rememberLabel
    self.isPlanReview = isPlanReview
    self.execPolicyAmendment = execPolicyAmendment
  }
}

public struct ConversationSnapshot: Identifiable, Codable, Equatable, Sendable {
  public var id: String { session.id }
  public var revision: Int
  public var session: SessionSummary
  public var messages: [ConversationMessage]
  public var decisions: [DecisionRequest]
  public var eventState: SessionEventState?

  public var pendingDecisions: [DecisionRequest] {
    decisions.filter { $0.response == nil }
  }

  public init(
    revision: Int, session: SessionSummary, messages: [ConversationMessage],
    decisions: [DecisionRequest] = [], eventState: SessionEventState? = nil
  ) {
    self.revision = revision
    self.session = session
    self.messages = messages
    self.decisions = decisions
    self.eventState = eventState
  }
}

public enum SessionClientError: Error, LocalizedError, Equatable, Sendable {
  case sessionNotFound
  case readOnly
  case emptyMessage
  case busy
  case needsDecision
  case decisionNotFound
  case decisionAlreadyResolved
  case invalidDecision
  case invalidTitle
  case archived

  public var errorDescription: String? {
    switch self {
    case .sessionNotFound: return "This session is no longer available."
    case .readOnly: return "You have read-only access to this session."
    case .emptyMessage: return "Write a message before sending."
    case .busy: return "Wait for the reply or stop it before sending another message."
    case .needsDecision: return "Respond to the pending request before sending a message."
    case .decisionNotFound: return "This request is no longer available."
    case .decisionAlreadyResolved: return "This request has already been answered."
    case .invalidDecision: return "Choose a valid response for this request."
    case .invalidTitle: return "Use a session name between 1 and 120 characters."
    case .archived: return "Restore this session before sending a message."
    }
  }
}
