import Foundation

public struct LocalServerInfo: Equatable, Sendable {
  public let baseURL: URL
  public let userID: String

  public var scope: ServerIdentityScope {
    ServerIdentityScope(serverURL: baseURL, userID: userID)
  }
}

public struct SessionPage: Equatable, Sendable {
  public let sessions: [SessionSummary]
  public let nextCursor: String?
}

public struct ConversationHistoryPage: Equatable, Sendable {
  public let messages: [ConversationMessage]
  public let nextCursor: String?
}

public struct LocalConversationPage: Equatable, Sendable {
  public let snapshot: ConversationSnapshot
  public let nextCursor: String?
  var configurationEpoch: UInt64 = 0
}

public enum LocalServerClientError: Error, LocalizedError, Equatable, Sendable {
  case invalidBaseURL
  case notConnected
  case unsupportedAuthentication
  case identityUnavailable
  case identityMismatch
  case browserLoginExpired
  case invalidIdentifier
  case invalidPageLimit
  case invalidPagination
  case malformedResponse
  case redirectNotAllowed
  case unauthorized
  case forbidden
  case httpStatus(Int)
  case transport(Int)
  case deliveryUncertain
  case streamNotReady
  case executionUnavailable(String)
  case messageDenied
  case creationRequiresHost
  case unsupportedDecision
  case watchLimitExceeded

  public var errorDescription: String? {
    switch self {
    case .invalidBaseURL:
      return
        "Use an HTTPS API URL including its mount path, or an HTTP loopback root for local mode. Databricks workspace hosts allow one numeric ?o=workspace-id selector. Omit credentials, fragments, and other query parameters."
    case .notConnected:
      return "Connect to the server before loading sessions."
    case .unsupportedAuthentication:
      return
        "This authentication method is unavailable for this deployment. Use hosted bearer authentication or explicit local single-user mode."
    case .identityUnavailable:
      return "The server did not confirm an authenticated identity."
    case .identityMismatch:
      return "The authenticated account differs from the saved account. Sign out and reconnect."
    case .browserLoginExpired:
      return "Browser login expired. Start a new sign-in."
    case .invalidIdentifier:
      return "The session identifier is invalid. Refresh the session list."
    case .invalidPageLimit:
      return "Request between 1 and 1,000 items per page."
    case .invalidPagination:
      return "The server returned an invalid page cursor. Refresh and try again."
    case .malformedResponse:
      return "The server returned data this app could not read. Check the server version."
    case .redirectNotAllowed:
      return "The server redirected this request. Use the direct API address."
    case .unauthorized:
      return "Sign in again or provide a valid bearer token for this server."
    case .forbidden:
      return "The server denied access to this resource."
    case .httpStatus(let status):
      return "The server returned HTTP \(status). Check that it is running and try again."
    case .transport(let code):
      return
        "Could not reach the server (network error \(code)). Check the address and network connection."
    case .deliveryUncertain:
      return
        "The server may have accepted this action, but confirmation was lost. Check the conversation before trying again."
    case .streamNotReady:
      return "Wait for the live connection to finish syncing before sending."
    case .executionUnavailable(let reason):
      return reason
    case .messageDenied:
      return "The server declined this message. Your draft has been preserved."
    case .creationRequiresHost:
      return
        "Create the session in the web app with a configured host and workspace, then open it here."
    case .unsupportedDecision:
      return "This request needs a form that is not supported here yet. Open it in the web app."
    case .watchLimitExceeded:
      return "Automatic updates support up to 500 sessions per connection. Narrow the watched set."
    }
  }
}

/// Identity-bound transport for hosted HTTPS and explicit loopback single-user servers.
public actor LocalServerSessionClient: SessionClient {
  public let baseURL: URL
  let endpoint: ServerEndpoint
  private let bearerToken: String?
  private let expectedUserID: String?
  var confirmedUserID: String?
  var connectionGeneration = UUID()
  let session: URLSession
  let streamingSession: URLSession
  var connected = false
  public var isConnected: Bool { connected }
  var revision = 0
  var summaries: [String: SessionSummary] = [:]
  var configurationEpochs: [String: UInt64] = [:]
  var configurationRevision: UInt64 = 0
  var configurationMutations: Set<String> = []
  var snapshotListeners: [UUID: AsyncStream<ConversationSnapshot>.Continuation] = [:]
  var activityListeners: [UUID: AsyncStream<LocalServerActivity>.Continuation] = [:]
  var watchedSessionID: String?
  var streamGeneration = UUID()
  var streamTask: Task<Void, Never>?
  var streamDataTask: URLSessionTask?
  var hydrationTask: Task<Void, Never>?
  var changedFileTasks: [String: Task<Void, Never>] = [:]
  var changedFileEpochs: [String: UInt64] = [:]
  var streamReady = false
  var receivedHeartbeat = false
  var isHydrating = false
  var hydrationRequestedAgain = false
  var hydrationRetryCount = 0
  var bufferedEvents: [[String: JSONValue]] = []
  var reducer: LiveConversationReducer?
  var listGeneration = UUID()
  var listTask: Task<Void, Never>?
  var listSocket: URLSessionWebSocketTask?
  var watchedIDs: [String] = []

  /// An injected session contributes configuration only; security settings remain enforced.
  public init(
    baseURL: URL, bearerToken: String? = nil, expectedUserID: String? = nil,
    session: URLSession? = nil
  ) throws {
    let endpoint = try ServerEndpoint(baseURL: baseURL)
    if let bearerToken {
      try ServerEndpoint.validateBearer(bearerToken)
      guard !endpoint.isLocalSingleUser else {
        throw LocalServerClientError.unsupportedAuthentication
      }
    }
    if let expectedUserID, expectedUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      throw LocalServerClientError.identityUnavailable
    }
    self.endpoint = endpoint
    self.baseURL = endpoint.baseURL
    self.bearerToken = bearerToken
    self.expectedUserID = expectedUserID
    let configuration = secureServerConfiguration(session)
    self.session = URLSession(
      configuration: configuration, delegate: ServerTransportDelegate(), delegateQueue: nil)
    let streamingConfiguration = configuration.copy() as! URLSessionConfiguration
    streamingConfiguration.timeoutIntervalForRequest = 60
    streamingConfiguration.timeoutIntervalForResource = 24 * 60 * 60
    self.streamingSession = URLSession(
      configuration: streamingConfiguration, delegate: ServerTransportDelegate(),
      delegateQueue: nil)
  }

  deinit {
    session.invalidateAndCancel()
    streamingSession.invalidateAndCancel()
    streamTask?.cancel()
    hydrationTask?.cancel()
    listTask?.cancel()
    for listener in snapshotListeners.values { listener.finish() }
    for listener in activityListeners.values { listener.finish() }
  }

  public func connect() async throws -> LocalServerInfo {
    disconnect()
    let info: ServerInfoWire = try await get(path: "/v1/info")
    if endpoint.isLocalSingleUser {
      guard info.singleUser, !info.accountsEnabled, info.loginURL == nil else {
        throw LocalServerClientError.unsupportedAuthentication
      }
    } else {
      guard bearerToken != nil else { throw LocalServerClientError.unauthorized }
      guard !info.singleUser || info.accountsEnabled || info.loginURL != nil else {
        throw LocalServerClientError.unsupportedAuthentication
      }
    }
    let identity: IdentityWire = try await get(path: "/v1/me")
    guard let userID = identity.userID,
      !userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !endpoint.isLocalSingleUser || userID == "local"
    else { throw LocalServerClientError.identityUnavailable }
    guard expectedUserID.map({ $0 == userID }) ?? true,
      confirmedUserID.map({ $0 == userID }) ?? true
    else { throw LocalServerClientError.identityMismatch }
    confirmedUserID = userID
    connected = true
    return LocalServerInfo(baseURL: baseURL, userID: userID)
  }

  /// Credentials and identity are immutable for the client's lifetime. Use a new client to switch.
  public func disconnect() {
    connectionGeneration = UUID()
    connected = false
    stopWatching()
    stopSessionListUpdates()
    summaries.removeAll()
    configurationEpochs.removeAll()
    configurationMutations.removeAll()
  }

  func authenticationFailed() {
    let selected = watchedSessionID
    disconnect()
    let message = LocalServerClientError.unauthorized.localizedDescription
    if let selected { emit(.streamState(sessionID: selected, state: .failed(message))) }
    emit(.listState(.failed(message)))
  }

  public func sessions() async throws -> [SessionSummary] {
    try await sessionPage().sessions
  }

  public func sessionPage(after: String? = nil, limit: Int = 50) async throws -> SessionPage {
    try requireConnection()
    var query = try pageQuery(after: after, limit: limit)
    query.append(URLQueryItem(name: "sort_by", value: "updated_at"))
    query.append(URLQueryItem(name: "include_archived", value: "true"))
    let epochs = configurationEpochs
    let page: PageWire<SessionWire> = try await get(path: "/v1/sessions", query: query)
    let nextCursor = try page.nextCursor(after: after)
    var seen = Set<String>()
    var result: [SessionSummary] = []
    for wire in page.data where seen.insert(wire.id).inserted {
      let summary = recordConfigurationSummary(
        try summaryPreservingNewerState(wire, epoch: epochs[wire.id, default: 0]))
      result.append(summary)
      cacheSummary(summary)
    }
    return SessionPage(sessions: result, nextCursor: nextCursor)
  }

  public func historyPage(
    sessionID: String, after: String? = nil, limit: Int = 50
  ) async throws -> ConversationHistoryPage {
    try requireConnection()
    try validateIdentifier(sessionID)
    let query = try pageQuery(after: after, limit: limit)
    let page: PageWire<ItemWire> = try await get(
      path: "/v1/sessions/\(sessionID)/items", query: query)
    let nextCursor = try page.nextCursor(after: after)
    var seen = Set<String>()
    var descending: [ConversationMessage] = []
    for item in page.data where seen.insert(item.id).inserted {
      if let message = try item.message() {
        descending.append(message)
      }
    }
    return ConversationHistoryPage(messages: descending.reversed(), nextCursor: nextCursor)
  }

  public func conversation(id: String) async throws -> ConversationSnapshot {
    try await conversationPage(id: id).snapshot
  }

  public func conversationPage(id: String, limit: Int = 50) async throws -> LocalConversationPage {
    try requireConnection()
    try validateIdentifier(id)
    _ = try pageQuery(after: nil, limit: limit)
    let epoch = configurationEpochs[id, default: 0]
    let wire: SessionWire = try await get(
      path: "/v1/sessions/\(id)",
      query: [URLQueryItem(name: "include_items", value: "false")])
    guard wire.id == id else { throw LocalServerClientError.malformedResponse }
    let history = try await historyPage(sessionID: id, limit: limit)
    let summary = recordConfigurationSummary(try summaryPreservingNewerState(wire, epoch: epoch))
    let decisions = try (wire.pendingElicitations ?? []).map {
      try ElicitationWire(value: $0, sessionID: id).decision
    }
    revision += 1
    cacheSummary(summary)
    return LocalConversationPage(
      snapshot: ConversationSnapshot(
        revision: revision, session: summary, messages: history.messages, decisions: decisions,
        eventState: wire.eventState),
      nextCursor: history.nextCursor, configurationEpoch: configurationEpochs[id, default: 0])
  }

  public func updates() async -> AsyncStream<ConversationSnapshot> {
    let id = UUID()
    let (stream, continuation) = AsyncStream<ConversationSnapshot>.makeStream(
      bufferingPolicy: .bufferingNewest(8))
    snapshotListeners[id] = continuation
    if let snapshot = reducer?.snapshot { continuation.yield(snapshot) }
    continuation.onTermination = { [weak self] _ in
      Task { await self?.removeSnapshotListener(id) }
    }
    return stream
  }

  public func send(_ text: String, to sessionID: String) async throws {
    let result = try await submitMessage(text, to: sessionID)
    if result.denied { throw LocalServerClientError.messageDenied }
  }

  public func submitMessage(_ text: String, to sessionID: String) async throws -> MessageSubmission
  {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw SessionClientError.emptyMessage
    }
    let summary = try await editableSession(sessionID)
    guard !summary.isArchived else { throw SessionClientError.archived }
    if let reason = summary.configuration?.executionUnavailableReason {
      throw LocalServerClientError.executionUnavailable(reason)
    }
    guard watchedSessionID == sessionID, streamReady else {
      throw LocalServerClientError.streamNotReady
    }
    return try await mutation(
      path: "/v1/sessions/\(sessionID)/events",
      body: .object([
        "type": .string("message"),
        "data": .object([
          "role": .string("user"),
          "content": .array([.object(["type": .string("input_text"), "text": .string(text)])]),
        ]),
      ]))
  }

  public func interrupt(sessionID: String) async throws {
    _ = try await editableSession(sessionID)
    let _: MessageSubmission = try await mutation(
      path: "/v1/sessions/\(sessionID)/events",
      body: .object(["type": .string("interrupt"), "data": .object([:])]))
    rehydrateAfterMutation(sessionID: sessionID)
  }

  public func resolve(
    decisionID: String, sessionID: String, response: DecisionResponse
  ) async throws {
    try validateIdentifier(decisionID)
    _ = try await editableSession(sessionID)
    let current = try await conversationPage(id: sessionID)
    guard let decision = current.snapshot.pendingDecisions.first(where: { $0.id == decisionID })
    else {
      throw SessionClientError.decisionNotFound
    }
    guard decision.unsupportedReason == nil else {
      throw LocalServerClientError.unsupportedDecision
    }
    guard decision.externalURL == nil else { throw LocalServerClientError.unsupportedDecision }
    let target = decision.targetSessionID
    try validateIdentifier(target)
    if target != sessionID { _ = try await editableSession(target) }
    var body: [String: JSONValue] = [:]
    switch response {
    case .approve:
      guard decision.options.isEmpty, decision.answerKey == nil, decision.form == nil else {
        throw SessionClientError.invalidDecision
      }
      body["action"] = .string("accept")
    case .decline: body["action"] = .string("decline")
    case .answer(let answer):
      guard let key = decision.answerKey, decision.options.contains(answer) else {
        throw SessionClientError.invalidDecision
      }
      body["action"] = .string("accept")
      body["content"] = .object([key: .string(answer)])
    case .form(let values):
      guard let form = decision.form, form.validationError(values: values) == nil else {
        throw SessionClientError.invalidDecision
      }
      body["action"] = .string("accept")
      body["content"] = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(values))
    case .approveAllEdits:
      guard decision.allowAllEdits == true else { throw SessionClientError.invalidDecision }
      body = ["action": .string("accept"), "content": .object(["allow_all_edits": .bool(true)])]
    case .approveRemembering:
      guard decision.rememberLabel != nil else { throw SessionClientError.invalidDecision }
      body = ["action": .string("accept"), "content": .object(["remember": .bool(true)])]
    case .declineWithFeedback(let feedback):
      guard decision.isPlanReview == true,
        !feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        throw SessionClientError.invalidDecision
      }
      body = ["action": .string("decline"), "content": .object(["feedback": .string(feedback)])]
    case .approveCommandPolicy(let amendment):
      guard !amendment.isEmpty, amendment == decision.execPolicyAmendment else {
        throw SessionClientError.invalidDecision
      }
      body = [
        "action": .string("accept"),
        "content": .object(["execpolicy_amendment": .array(amendment.map(JSONValue.string))]),
      ]
    }
    let _: MessageSubmission = try await mutation(
      path: "/v1/sessions/\(target)/elicitations/\(decisionID)/resolve", body: .object(body))
    rehydrateAfterMutation(sessionID: sessionID)
    emit(.inventoryInvalidated)
  }

  public func createSession(title: String) async throws -> ConversationSnapshot {
    throw LocalServerClientError.creationRequiresHost
  }

  public func editSession(_ sessionID: String, change: SessionChange) async throws {
    try requireConnection()
    try validateIdentifier(sessionID)
    let wire: SessionWire = try await get(
      path: "/v1/sessions/\(sessionID)",
      query: [URLQueryItem(name: "include_items", value: "false")])
    let summary = try wire.summary(previous: summaries[sessionID])
    let body: JSONValue
    switch change {
    case .title(let title):
      guard summary.canRename else { throw SessionClientError.readOnly }
      let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !cleaned.isEmpty, cleaned.count <= 120 else { throw SessionClientError.invalidTitle }
      body = .object(["title": .string(cleaned)])
    case .pinned(let pinned):
      guard summary.canPin else { throw SessionClientError.readOnly }
      body = .object([
        "labels": .object([
          "omnigent.pinned": .string(
            pinned ? String(Int(Date().timeIntervalSince1970 * 1_000)) : "")
        ])
      ])
    case .archived(let archived):
      guard summary.canArchive else { throw SessionClientError.readOnly }
      body = .object(["archived": .bool(archived)])
    }
    let mutationEpoch = configurationEpochs[sessionID, default: 0]
    let updated: SessionWire = try await mutation(
      path: "/v1/sessions/\(sessionID)", method: "PATCH", body: body)
    let updatedSummary = recordConfigurationSummary(
      try summaryPreservingNewerState(updated, epoch: mutationEpoch))
    cacheSummary(updatedSummary)
    emit(.sessionsChanged([updatedSummary]))
    rehydrateAfterMutation(sessionID: sessionID)
  }

  func editableSession(_ id: String) async throws -> SessionSummary {
    try requireConnection()
    try validateIdentifier(id)
    let epoch = configurationEpochs[id, default: 0]
    let wire: SessionWire = try await get(
      path: "/v1/sessions/\(id)", query: [URLQueryItem(name: "include_items", value: "false")])
    let summary = recordConfigurationSummary(try summaryPreservingNewerState(wire, epoch: epoch))
    guard !summary.isReadOnly else { throw SessionClientError.readOnly }
    cacheSummary(summary)
    return summary
  }

  func summaryPreservingNewerState(_ wire: SessionWire, epoch: UInt64) throws -> SessionSummary {
    if epoch != configurationEpochs[wire.id, default: 0], let current = summaries[wire.id] {
      return current
    }
    return try wire.summary(previous: summaries[wire.id])
  }

  func requireConnection() throws {
    guard connected else { throw LocalServerClientError.notConnected }
  }

  func validateIdentifier(_ id: String) throws {
    let allowed = CharacterSet(
      charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
    guard !id.isEmpty, id.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
      throw LocalServerClientError.invalidIdentifier
    }
  }

  func pageQuery(after: String?, limit: Int) throws -> [URLQueryItem] {
    guard (1...1_000).contains(limit) else { throw LocalServerClientError.invalidPageLimit }
    var query = [
      URLQueryItem(name: "limit", value: String(limit)),
      URLQueryItem(name: "order", value: "desc"),
    ]
    if let after {
      guard !after.isEmpty else { throw LocalServerClientError.invalidPagination }
      query.append(URLQueryItem(name: "after", value: after))
    }
    return query
  }

  func request(
    path: String, query: [URLQueryItem] = [], accept: String = "application/json",
    webSocket: Bool = false
  ) throws -> URLRequest {
    try endpoint.request(
      path: path, query: query, accept: accept,
      bearerToken: bearerToken, webSocket: webSocket)
  }

  func mutation<Value: Decodable>(path: String, method: String = "POST", body: JSONValue)
    async throws -> Value
  {
    var outgoing = try request(path: path)
    outgoing.httpMethod = method
    outgoing.setValue("application/json", forHTTPHeaderField: "Content-Type")
    outgoing.httpBody = try JSONEncoder().encode(body)
    return try await perform(outgoing, mutation: true)
  }

  func get<Value: Decodable>(path: String, query: [URLQueryItem] = []) async throws -> Value {
    try await perform(request(path: path, query: query), mutation: false)
  }

  func perform<Value: Decodable>(_ request: URLRequest, mutation: Bool) async throws -> Value {
    let generation = connectionGeneration
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch is CancellationError {
      if mutation { throw LocalServerClientError.deliveryUncertain }
      throw CancellationError()
    } catch let error as URLError {
      if error.code == .cancelled {
        if mutation { throw LocalServerClientError.deliveryUncertain }
        throw CancellationError()
      }
      if error.code == .userAuthenticationRequired || error.code == .userCancelledAuthentication {
        if generation == connectionGeneration { authenticationFailed() }
        throw LocalServerClientError.unauthorized
      }
      if mutation { throw LocalServerClientError.deliveryUncertain }
      throw LocalServerClientError.transport(error.code.rawValue)
    } catch {
      if mutation { throw LocalServerClientError.deliveryUncertain }
      throw LocalServerClientError.transport(URLError.unknown.rawValue)
    }
    guard generation == connectionGeneration else {
      if mutation { throw LocalServerClientError.deliveryUncertain }
      throw LocalServerClientError.notConnected
    }
    guard let http = response as? HTTPURLResponse else {
      if mutation { throw LocalServerClientError.deliveryUncertain }
      throw LocalServerClientError.malformedResponse
    }
    guard http.url == request.url else { throw LocalServerClientError.redirectNotAllowed }
    switch http.statusCode {
    case 200, 202: break
    case 300...399: throw LocalServerClientError.redirectNotAllowed
    case 401:
      authenticationFailed()
      throw LocalServerClientError.unauthorized
    case 403: throw LocalServerClientError.forbidden
    default:
      if mutation && http.statusCode >= 500 { throw LocalServerClientError.deliveryUncertain }
      throw LocalServerClientError.httpStatus(http.statusCode)
    }
    do {
      return try JSONDecoder().decode(Value.self, from: data)
    } catch {
      if mutation { throw LocalServerClientError.deliveryUncertain }
      throw LocalServerClientError.malformedResponse
    }
  }
}

private struct IdentityWire: Decodable {
  let userID: String?

  enum CodingKeys: String, CodingKey {
    case userID = "user_id"
  }
}

struct PageWire<Item: Decodable>: Decodable {
  let data: [Item]
  let lastID: String?
  let hasMore: Bool

  enum CodingKeys: String, CodingKey {
    case data
    case lastID = "last_id"
    case hasMore = "has_more"
  }

  func nextCursor(after: String?) throws -> String? {
    guard hasMore else { return nil }
    guard let lastID, !lastID.isEmpty, lastID != after else {
      throw LocalServerClientError.invalidPagination
    }
    return lastID
  }
}

struct SessionWire: Decodable {
  let eventState: SessionEventState
  let id: String
  let status: String
  let createdAt: Double
  let updatedAt: Double?
  let title: String?
  let agentName: String?
  let workspace: String?
  let labels: [String: String]?
  let archived: Bool?
  let pendingCount: Int?
  let pendingElicitations: [JSONValue]?
  let searchSnippet: String?
  let permissionLevel: Int?
  let lastTaskError: [String: JSONValue]?
  let agentID: String?
  let harness: String?
  let modelOverride: String?
  let baseModel: String?
  let effort: String?
  let modelOptions: [ModelChoice]?
  let hostID: String?
  let hostOnline: Bool?
  let runnerOnline: Bool?
  let runnerID: String?
  let hostResumable: Bool?
  let parentID: String?
  let routingMode: String?
  private let presentFields: Set<CodingKeys>

  var hasConfigurationIdentity: Bool {
    presentFields.contains(.harness) && presentFields.contains(.modelOverride)
  }

  enum CodingKeys: String, CodingKey, CaseIterable {
    case id, status, title, workspace, labels, archived
    case createdAt = "created_at"
    case updatedAt = "updated_at"
    case agentName = "agent_name"
    case pendingCount = "pending_elicitations_count"
    case pendingElicitations = "pending_elicitations"
    case searchSnippet = "search_snippet"
    case permissionLevel = "permission_level"
    case lastTaskError = "last_task_error"
    case agentID = "agent_id"
    case harness
    case modelOverride = "model_override"
    case baseModel = "llm_model"
    case effort = "reasoning_effort"
    case modelOptions = "model_options"
    case hostID = "host_id"
    case hostOnline = "host_online"
    case runnerOnline = "runner_online"
    case runnerID = "runner_id"
    case hostResumable = "host_resumable"
    case parentID = "parent_session_id"
    case routingMode = "cost_control_mode_override"
  }

  init(from decoder: Decoder) throws {
    eventState = SessionEventState(snapshot: try JSONValue(from: decoder).object ?? [:])
    let values = try decoder.container(keyedBy: CodingKeys.self)
    presentFields = Set(CodingKeys.allCases.filter { values.contains($0) })
    id = try values.decode(String.self, forKey: .id)
    status = try values.decode(String.self, forKey: .status)
    createdAt = try values.decode(Double.self, forKey: .createdAt)
    updatedAt = try values.decodeIfPresent(Double.self, forKey: .updatedAt)
    title = try values.decodeIfPresent(String.self, forKey: .title)
    agentName = try values.decodeIfPresent(String.self, forKey: .agentName)
    workspace = try values.decodeIfPresent(String.self, forKey: .workspace)
    labels = try values.decodeIfPresent([String: String].self, forKey: .labels)
    archived = try values.decodeIfPresent(Bool.self, forKey: .archived)
    pendingCount = try values.decodeIfPresent(Int.self, forKey: .pendingCount)
    pendingElicitations = try values.decodeIfPresent([JSONValue].self, forKey: .pendingElicitations)
    searchSnippet = try values.decodeIfPresent(String.self, forKey: .searchSnippet)
    permissionLevel = try values.decodeIfPresent(Int.self, forKey: .permissionLevel)
    lastTaskError = try values.decodeIfPresent([String: JSONValue].self, forKey: .lastTaskError)
    agentID = try values.decodeIfPresent(String.self, forKey: .agentID)
    harness = try values.decodeIfPresent(String.self, forKey: .harness)
    modelOverride = try values.decodeIfPresent(String.self, forKey: .modelOverride)
    baseModel = try values.decodeIfPresent(String.self, forKey: .baseModel)
    effort = try values.decodeIfPresent(String.self, forKey: .effort)
    modelOptions = try values.decodeIfPresent([ModelChoice].self, forKey: .modelOptions)
    hostID = try values.decodeIfPresent(String.self, forKey: .hostID)
    hostOnline = try values.decodeIfPresent(Bool.self, forKey: .hostOnline)
    runnerOnline = try values.decodeIfPresent(Bool.self, forKey: .runnerOnline)
    runnerID = try values.decodeIfPresent(String.self, forKey: .runnerID)
    hostResumable = try values.decodeIfPresent(Bool.self, forKey: .hostResumable)
    parentID = try values.decodeIfPresent(String.self, forKey: .parentID)
    routingMode = try values.decodeIfPresent(String.self, forKey: .routingMode)
  }

  func summary(previous: SessionSummary?) throws -> SessionSummary {
    guard !id.isEmpty, createdAt.isFinite, updatedAt?.isFinite ?? true else {
      throw LocalServerClientError.malformedResponse
    }
    let hasPending = (pendingCount ?? 0) > 0 || !(pendingElicitations ?? []).isEmpty
    let mappedStatus: SessionStatus
    let statusPreview: String
    switch status {
    case "idle":
      mappedStatus = .idle
      statusPreview = "Idle"
    case "running", "waiting", "launching":
      mappedStatus = .running
      statusPreview = status.capitalized
    case "failed":
      mappedStatus = .idle
      statusPreview = "Failed"
    default:
      throw LocalServerClientError.malformedResponse
    }
    let prior = previous?.configuration
    let sameAgent =
      (!presentFields.contains(.agentID) || agentID == prior?.agentID)
      && (!presentFields.contains(.harness) || harness == prior?.harness)
    // List projections omit detail fields; explicit nulls still clear confirmed values.
    var configuration = sameAgent ? prior ?? SessionConfiguration() : SessionConfiguration()
    // Execution belongs to the session, even when a sparse update changes its harness.
    configuration.hostID = prior?.hostID
    configuration.hostOnline = prior?.hostOnline
    configuration.runnerOnline = prior?.runnerOnline
    configuration.runnerBound = prior?.runnerBound
    configuration.hostResumable = prior?.hostResumable
    if presentFields.contains(.agentID) { configuration.agentID = agentID }
    if presentFields.contains(.harness) { configuration.harness = harness }
    if presentFields.contains(.labels) { configuration.wrapper = labels?["omnigent.wrapper"] }
    if presentFields.contains(.modelOverride) {
      configuration.modelOverride = modelOverride
      configuration.modelReported = true
    }
    if presentFields.contains(.baseModel) { configuration.baseModel = baseModel }
    if presentFields.contains(.effort) {
      configuration.effort = effort
      configuration.effortReported = true
    }
    if presentFields.contains(.modelOptions) { configuration.models = modelOptions ?? [] }
    if presentFields.contains(.hostID) {
      if configuration.hostID != hostID {
        configuration.hostOnline = nil
        configuration.runnerOnline = nil
        configuration.runnerBound = nil
        configuration.hostResumable = nil
      }
      configuration.hostID = hostID
    }
    if presentFields.contains(.hostOnline) { configuration.hostOnline = hostOnline }
    if presentFields.contains(.runnerOnline) { configuration.runnerOnline = runnerOnline }
    if presentFields.contains(.runnerID) { configuration.runnerBound = !(runnerID ?? "").isEmpty }
    if presentFields.contains(.hostResumable) { configuration.hostResumable = hostResumable }
    if presentFields.contains(.parentID) { configuration.parentID = parentID }
    if presentFields.contains(.routingMode) { configuration.routingMode = routingMode }
    let effectivePermission =
      presentFields.contains(.permissionLevel) ? permissionLevel : previous?.permissionLevel
    return SessionSummary(
      id: id,
      title: title.flatMap({ $0.isEmpty ? nil : $0 }) ?? "Untitled session",
      preview: hasPending
        ? "Needs your response" : (searchSnippet ?? statusPreview),
      status: hasPending ? .needsResponse : mappedStatus,
      isReadOnly: effectivePermission.map { $0 < 2 }
        ?? (presentFields.contains(.permissionLevel) ? true : previous?.isReadOnly ?? true),
      updatedAt: updatedAt.map(Date.init(timeIntervalSince1970:))
        ?? previous?.updatedAt ?? Date(timeIntervalSince1970: createdAt),
      workspace: workspace ?? "Local server",
      agentName: agentName ?? "Omnigent",
      isPinned: !(labels?["omnigent.pinned"] ?? "").isEmpty,
      isArchived: archived ?? false, permissionLevel: effectivePermission,
      failureMessage: status == "failed"
        ? (lastTaskError?["message"]?.string
          ?? "The last response failed. Check the server or provider sign-in.") : nil,
      configuration: configuration)
  }
}

struct ItemWire: Decodable {
  let payload: [String: JSONValue]

  var id: String { payload["id"]?.string ?? "" }
  var type: String { payload["type"]?.string ?? "" }
  var role: String? { payload["role"]?.string }
  var content: JSONValue? { payload["content"] }
  var name: String? { payload["name"]?.string }
  var arguments: JSONValue? { payload["arguments"] }
  var output: JSONValue? { payload["output"] }
  var isMeta: Bool? { payload["is_meta"]?.bool }
  var code: String? { payload["code"]?.string }
  var errorMessage: String? { payload["message"]?.string }
  var callID: String? { payload["call_id"]?.string }
  var responseID: String? { payload["response_id"]?.string }
  var status: String? { payload["status"]?.string }

  init(payload: [String: JSONValue]) {
    self.payload = payload
  }

  init(from decoder: Decoder) throws {
    payload = try [String: JSONValue](from: decoder)
  }

  func message() throws -> ConversationMessage? {
    guard !id.isEmpty, !type.isEmpty else { throw LocalServerClientError.malformedResponse }
    return try ConversationItemPresentation(item: self).message()
  }
}

indirect enum JSONValue: Codable, Equatable, Sendable {
  case string(String)
  case object([String: JSONValue])
  case array([JSONValue])
  case number(Double)
  case bool(Bool)
  case null

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }

  var string: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }

  var object: [String: JSONValue]? {
    guard case .object(let value) = self else { return nil }
    return value
  }

  var array: [JSONValue]? {
    guard case .array(let value) = self else { return nil }
    return value
  }

  var int: Int? {
    guard case .number(let value) = self, value.isFinite, value >= Double(Int.min),
      value < Double(Int.max)
    else { return nil }
    return Int(value)
  }

  var bool: Bool? {
    guard case .bool(let value) = self else { return nil }
    return value
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .null: try container.encodeNil()
    }
  }

  var displayText: String {
    safeDisplayText
  }

  func messageText() throws -> String {
    try ConversationContentPresentation(value: self, itemID: "content").text
  }
}
