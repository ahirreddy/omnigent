import Foundation

extension LocalServerSessionClient {
  public func sessionCreationCatalog() async throws -> SessionCreationCatalog {
    try requireConnection()
    struct Hosts: Decodable { let hosts: [CreationHost] }
    let hosts: Hosts = try await get(path: "/v1/hosts")
    var agents: [CreationAgent] = []
    var after: String?
    var cursors = Set<String>()
    repeat {
      let page: PageWire<CreationAgent> = try await get(
        path: "/v1/agents", query: pageQuery(after: after, limit: 1000))
      agents += page.data
      after = try page.nextCursor(after: after)
      if let after, !cursors.insert(after).inserted {
        throw LocalServerClientError.invalidPagination
      }
    } while after != nil
    var seenAgents = Set<String>()
    var seenHosts = Set<String>()
    return SessionCreationCatalog(
      hosts: hosts.hosts.filter { !$0.id.isEmpty && seenHosts.insert($0.id).inserted },
      agents: agents.filter { !$0.id.isEmpty && seenAgents.insert($0.id).inserted })
  }

  /// Offers directories in the host's home folder; other absolute paths may be entered directly.
  public func creationWorkspaces(hostID: String) async throws -> [CreationWorkspace] {
    try requireConnection()
    try validateIdentifier(hostID)
    struct Entry: Decodable {
      let name: String
      let path: String
      let type: String
    }
    struct Page: Decodable {
      let data: [Entry]
      let hasMore: Bool
      enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
      }
    }
    var results: [CreationWorkspace] = []
    var after: String?
    var seen = Set<String>()
    var cursors = Set<String>()
    while true {
      let page: Page = try await get(
        path: "/v1/hosts/\(hostID)/filesystem", query: pageQuery(after: after, limit: 1000))
      for entry in page.data where entry.type == "directory" && entry.path.hasPrefix("/") {
        if seen.insert(entry.path).inserted {
          results.append(CreationWorkspace(path: entry.path, name: entry.name))
        }
      }
      if !page.hasMore { break }
      // Host filesystem pagination uses the final entry's absolute path.
      guard let cursor = page.data.last?.path, !cursor.isEmpty,
        cursors.insert(cursor).inserted
      else { throw LocalServerClientError.invalidPagination }
      after = cursor
    }
    return results
  }

  public func creationModels(agentID: String, hostID: String) async throws -> [ModelChoice] {
    let catalog = try await sessionCreationCatalog()
    if let reason = catalog.unavailableReason(agentID: agentID, hostID: hostID) {
      throw SessionCreationError.unavailable(reason)
    }
    guard let agent = catalog.agents.first(where: { $0.id == agentID }) else {
      throw SessionCreationError.unavailable("Choose a registered agent.")
    }
    return try await creationModels(agent: agent, hostID: hostID)
  }

  private func creationModels(agent: CreationAgent, hostID: String) async throws -> [ModelChoice] {
    guard agent.supportsModelPreview else { return [] }
    try validateIdentifier(hostID)
    try validateIdentifier(agent.harnessID)
    struct Response: Decodable { let models: [ModelChoice] }
    let response: Response = try await get(
      path: "/v1/hosts/\(hostID)/harnesses/\(agent.harnessID)/model-options")
    var seen = Set<String>()
    return response.models.filter {
      !$0.id.isEmpty && !$0.value.isEmpty && $0.hidden != true && seen.insert($0.value).inserted
    }
  }

  public func createSession(selection: SessionCreationSelection, title: String) async throws
    -> SessionCreationReceipt
  {
    try requireConnection()
    try validateIdentifier(selection.hostID)
    try validateIdentifier(selection.agentID)
    let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard name.count <= 120 else {
      throw SessionCreationError.unavailable("Use a session name of 120 characters or fewer.")
    }
    let catalog = try await sessionCreationCatalog()
    if let reason = catalog.unavailableReason(agentID: selection.agentID, hostID: selection.hostID)
    {
      throw SessionCreationError.unavailable(reason)
    }
    guard let agent = catalog.agents.first(where: { $0.id == selection.agentID }) else {
      throw SessionCreationError.unavailable("Choose a registered agent.")
    }
    let models =
      selection.model == nil ? [] : try await creationModels(agent: agent, hostID: selection.hostID)
    try catalog.validate(selection, models: models)
    try requireConnection()
    try Task.checkCancellation()
    var body: [String: JSONValue] = [
      "agent_id": .string(selection.agentID),
      "host_id": .string(selection.hostID),
      "host_type": .string("external"),
      "workspace": .string(selection.workspace.trimmingCharacters(in: .whitespacesAndNewlines)),
    ]
    if !name.isEmpty { body["title"] = .string(name) }
    if let model = selection.model { body["model_override"] = .string(model) }
    if let wrapper = agent.wrapper {
      body["labels"] = .object([
        "omnigent.ui": .string("terminal"), "omnigent.wrapper": .string(wrapper),
      ])
    }
    var outgoing = try request(path: "/v1/sessions")
    outgoing.httpMethod = "POST"
    outgoing.setValue("application/json", forHTTPHeaderField: "Content-Type")
    outgoing.httpBody = try JSONEncoder().encode(JSONValue.object(body))
    // Creation waits up to 30 seconds for host launch, after persisting the session.
    outgoing.timeoutInterval = 60
    let configuration = session.configuration
    configuration.timeoutIntervalForRequest = 60
    configuration.timeoutIntervalForResource = 75
    let creationSession = URLSession(
      configuration: configuration, delegate: SessionCreationDelegate(), delegateQueue: nil)
    defer { creationSession.invalidateAndCancel() }
    let generation = connectionGeneration
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await creationSession.data(for: outgoing)
    } catch {
      throw SessionCreationError.uncertain
    }
    guard generation == connectionGeneration else { throw SessionCreationError.uncertain }
    guard let http = response as? HTTPURLResponse, http.url == outgoing.url else {
      throw SessionCreationError.uncertain
    }
    if http.statusCode == 401 {
      authenticationFailed()
      throw LocalServerClientError.unauthorized
    }
    // Host launch can fail after the row was written, including with 403/404/409.
    if [400, 415, 422].contains(http.statusCode) {
      throw SessionCreationError.rejected(
        status: http.statusCode, message: creationRejection(data, status: http.statusCode))
    }
    guard [200, 201, 202].contains(http.statusCode),
      let object = try? JSONDecoder().decode(JSONValue.self, from: data).object,
      let id = object["id"]?.string, (try? validateIdentifier(id)) != nil
    else { throw SessionCreationError.uncertain }
    // A usable id is the creation acknowledgement even if a newer snapshot shape is unknown.
    let summary = (try? JSONDecoder().decode(SessionWire.self, from: data))
      .flatMap { try? $0.summary(previous: nil) }
    if let summary {
      cacheSummary(summary)
      emit(.sessionsChanged([summary]))
    }
    return SessionCreationReceipt(sessionID: id, summary: summary)
  }

  private func creationRejection(_ data: Data, status: Int) -> String {
    guard let object = try? JSONDecoder().decode(JSONValue.self, from: data).object else {
      return "The server rejected session creation (HTTP \(status)). Review your choices."
    }
    let message =
      object["error"]?.object?["message"]?.string
      ?? object["detail"]?.string
      ?? object["detail"]?.array?.compactMap { $0.object?["msg"]?.string }.joined(separator: "; ")
    return message.flatMap { $0.isEmpty ? nil : String($0.prefix(1000)) }
      ?? "The server rejected session creation (HTTP \(status)). Review your choices."
  }
}

private final class SessionCreationDelegate: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    handleServerChallenge(challenge, completionHandler: completionHandler)
  }
}
