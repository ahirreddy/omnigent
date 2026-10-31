import Foundation

extension LocalServerSessionClient {
  public func activityUpdates() async -> AsyncStream<LocalServerActivity> {
    let id = UUID()
    let (stream, continuation) = AsyncStream<LocalServerActivity>.makeStream(
      bufferingPolicy: .bufferingNewest(128))
    activityListeners[id] = continuation
    continuation.onTermination = { [weak self] _ in
      Task { await self?.removeActivityListener(id) }
    }
    return stream
  }

  public func startWatching(sessionID: String) async throws {
    try requireConnection()
    try validateIdentifier(sessionID)
    stopWatching()
    watchedSessionID = sessionID
    let generation = streamGeneration
    emit(.streamState(sessionID: sessionID, state: .connecting))
    streamTask = Task { [weak self] in
      await self?.runConversationStream(sessionID, generation: generation)
    }
  }

  public func stopWatching() {
    let previous = watchedSessionID
    streamGeneration = UUID()
    streamTask?.cancel()
    streamDataTask?.cancel()
    streamDataTask = nil
    hydrationTask?.cancel()
    for task in changedFileTasks.values { task.cancel() }
    changedFileTasks = [:]
    changedFileEpochs = [:]
    streamTask = nil
    hydrationTask = nil
    watchedSessionID = nil
    streamReady = false
    receivedHeartbeat = false
    isHydrating = false
    hydrationRequestedAgain = false
    hydrationRetryCount = 0
    bufferedEvents = []
    reducer = nil
    if let previous { emit(.streamState(sessionID: previous, state: .stopped)) }
  }

  public func sessionInventory() async throws -> [SessionSummary] {
    try requireConnection()
    var result: [SessionSummary] = []
    var ids = Set<String>()
    var cursors = Set<String>()
    var after: String?
    repeat {
      try Task.checkCancellation()
      var query = try pageQuery(after: after, limit: 500)
      query += [
        URLQueryItem(name: "include_archived", value: "true"),
        URLQueryItem(name: "kind", value: "any"),
        URLQueryItem(name: "sort_by", value: "updated_at"),
      ]
      let epochs = configurationEpochs
      let page: PageWire<SessionWire> = try await get(path: "/v1/sessions", query: query)
      for wire in page.data where ids.insert(wire.id).inserted {
        let summary = recordConfigurationSummary(
          try summaryPreservingNewerState(wire, epoch: epochs[wire.id, default: 0]))
        cacheSummary(summary)
        result.append(summary)
      }
      after = try page.nextCursor(after: after)
      if let after, !cursors.insert(after).inserted {
        throw LocalServerClientError.invalidPagination
      }
    } while after != nil
    return result
  }

  public func startSessionListUpdates(sessionIDs: [String]) async throws {
    try requireConnection()
    stopSessionListUpdates()
    try await setWatchedSessionIDs(sessionIDs)
    let generation = listGeneration
    emit(.listState(.connecting))
    listTask = Task { [weak self] in await self?.runSessionList(generation: generation) }
  }

  public func setWatchedSessionIDs(_ sessionIDs: [String]) async throws {
    try requireConnection()
    let unique = Array(Set(sessionIDs)).sorted()
    guard unique.count <= 500 else { throw LocalServerClientError.watchLimitExceeded }
    for id in unique { try validateIdentifier(id) }
    guard unique != watchedIDs else { return }
    watchedIDs = unique
    if let socket = listSocket { try await sendWatchSet(socket) }
  }

  public func stopSessionListUpdates() {
    listGeneration = UUID()
    listTask?.cancel()
    listSocket?.cancel(with: .goingAway, reason: nil)
    listSocket = nil
    listTask = nil
    watchedIDs = []
    emit(.listState(.stopped))
  }

  func removeSnapshotListener(_ id: UUID) { snapshotListeners.removeValue(forKey: id) }
  func removeActivityListener(_ id: UUID) { activityListeners.removeValue(forKey: id) }

  func emit(_ activity: LocalServerActivity) {
    for listener in activityListeners.values { listener.yield(activity) }
  }

  func publishSnapshot() {
    guard var current = reducer else { return }
    revision += 1
    current.snapshot.revision = revision
    // A provisional first-load summary must not supersede the metadata still being fetched.
    if !isHydrating || summaries[current.snapshot.id] != nil {
      current.snapshot.session = recordConfigurationSummary(current.snapshot.session)
      cacheSummary(current.snapshot.session)
    }
    reducer = current
    for listener in snapshotListeners.values { listener.yield(current.snapshot) }
  }

  func rehydrateAfterMutation(sessionID: String) {
    emit(.inventoryInvalidated)
    guard let selected = watchedSessionID else { return }
    if selected == sessionID
      || reducer?.snapshot.decisions.contains(where: { $0.targetSessionID == sessionID }) == true
    {
      beginHydration(sessionID: selected, generation: streamGeneration)
    }
  }

  private func runConversationStream(_ id: String, generation: UUID) async {
    var attempt = 0
    while !Task.isCancelled && generation == streamGeneration {
      do {
        streamReady = false
        receivedHeartbeat = false
        isHydrating = true
        hydrationRequestedAgain = false
        bufferedEvents = []
        reducer = nil
        var outgoing = try request(path: "/v1/sessions/\(id)/stream", accept: "text/event-stream")
        outgoing.timeoutInterval = 60
        let (bytes, response) = try await streamingSession.bytes(for: outgoing)
        guard generation == streamGeneration, !Task.isCancelled else {
          bytes.task.cancel()
          return
        }
        streamDataTask = bytes.task
        try validateStreamResponse(response, request: outgoing)
        guard generation == streamGeneration, !Task.isCancelled else { return }
        // Register before snapshot reads so live frames can also reconcile the result.
        launchHydration(sessionID: id, generation: generation)
        var parser = ServerSentEventByteParser()
        for try await byte in bytes {
          guard generation == streamGeneration, !Task.isCancelled else { return }
          guard let frame = try parser.consume(byte) else { continue }
          if frame.data == "[DONE]" {
            streamGeneration = UUID()
            streamDataTask?.cancel()
            streamDataTask = nil
            hydrationTask?.cancel()
            hydrationTask = nil
            isHydrating = false
            streamReady = false
            emit(.streamState(sessionID: id, state: .stopped))
            return
          }
          guard
            var event = try JSONDecoder().decode(JSONValue.self, from: Data(frame.data.utf8)).object
          else {
            throw LocalServerClientError.malformedResponse
          }
          if event["type"] == nil, let type = frame.event { event["type"] = .string(type) }
          if ["session.heartbeat", "response.heartbeat"].contains(event["type"]?.string ?? "") {
            receivedHeartbeat = true
            markStreamReadyIfHydrated(id)
            attempt = 0
            continue
          }
          try handleConversationEvent(event, sessionID: id)
        }
        throw LocalServerClientError.transport(URLError.networkConnectionLost.rawValue)
      } catch {
        guard generation == streamGeneration, !Task.isCancelled else { return }
        let error = streamFailure(error)
        if error as? LocalServerClientError == .unauthorized {
          authenticationFailed()
          return
        }
        streamReady = false
        streamDataTask?.cancel()
        streamDataTask = nil
        hydrationTask?.cancel()
        hydrationTask = nil
        isHydrating = false
        if !shouldReconnect(error) {
          emit(.streamState(sessionID: id, state: .failed(error.localizedDescription)))
          return
        }
        emit(.streamState(sessionID: id, state: .reconnecting))
        attempt += 1
        do { try await Task.sleep(nanoseconds: retryDelay(attempt)) } catch { return }
      }
    }
  }

  private func beginHydration(sessionID: String, generation: UUID) {
    guard !isHydrating else {
      hydrationRequestedAgain = true
      return
    }
    isHydrating = true
    bufferedEvents = []
    launchHydration(sessionID: sessionID, generation: generation)
  }

  private func launchHydration(sessionID: String, generation: UUID) {
    hydrationTask?.cancel()
    let baseline = reducer
    hydrationTask = Task { [weak self] in
      guard let self else { return }
      do {
        let page = try await self.conversationPage(id: sessionID)
        try Task.checkCancellation()
        try await self.finishHydration(page, generation: generation, baseline: baseline)
      } catch {
        await self.hydrationFailed(error, sessionID: sessionID, generation: generation)
      }
    }
  }

  func finishHydration(
    _ page: LocalConversationPage, generation: UUID, baseline: LiveConversationReducer? = nil
  ) throws {
    guard generation == streamGeneration, page.snapshot.id == watchedSessionID else { return }
    var authoritative = page.snapshot
    if page.configurationEpoch != configurationEpochs[page.snapshot.id, default: 0],
      let latest = summaries[page.snapshot.id]
    {
      authoritative.session = latest
    }
    var current: LiveConversationReducer
    if var existing = baseline {
      existing.reconcile(with: authoritative)
      current = existing
    } else {
      // A new SSE connection replays in-flight text; only that path resets indices.
      current = LiveConversationReducer(snapshot: authoritative)
    }
    let events = bufferedEvents
    bufferedEvents = []
    isHydrating = false
    hydrationTask = nil
    var reconcileAgain = hydrationRequestedAgain
    hydrationRequestedAgain = false
    hydrationRetryCount = 0
    for event in events {
      let effects = try current.apply(event)
      reconcileAgain = reconcileAgain || effects.reconcile
    }
    if var live = reducer {
      // Replay against the pre-read checkpoint, never against already-published deltas.
      // Keep the live reducer's previews and indices when merging the recovered history.
      var reconciled = current.snapshot
      reconciled.messages.removeAll { current.isEphemeral($0) }
      live.reconcile(with: reconciled)
      current = live
    }
    reducer = current
    if let failure = page.snapshot.session.failureMessage {
      emit(.conversationError(sessionID: page.snapshot.id, message: failure))
    }
    emit(
      .historyCursor(
        sessionID: page.snapshot.id, nextCursor: page.nextCursor,
        firstMessageID: page.snapshot.messages.first?.id))
    publishSnapshot()
    markStreamReadyIfHydrated(page.snapshot.id)
    if reconcileAgain { beginHydration(sessionID: page.snapshot.id, generation: generation) }
  }

  func hydrationFailed(_ error: Error, sessionID: String, generation: UUID) {
    guard generation == streamGeneration, !(error is CancellationError) else { return }
    streamReady = false
    isHydrating = false
    streamTask?.cancel()
    streamDataTask?.cancel()
    streamDataTask = nil
    if shouldReconnect(error) {
      streamGeneration = UUID()
      let nextGeneration = streamGeneration
      hydrationRetryCount += 1
      let delay = retryDelay(hydrationRetryCount)
      emit(.streamState(sessionID: sessionID, state: .reconnecting))
      streamTask = Task { [weak self] in
        do { try await Task.sleep(nanoseconds: delay) } catch { return }
        await self?.runConversationStream(sessionID, generation: nextGeneration)
      }
      return
    }
    emit(.streamState(sessionID: sessionID, state: .failed(error.localizedDescription)))
  }

  private func markStreamReadyIfHydrated(_ id: String) {
    guard streamDataTask != nil, receivedHeartbeat, !isHydrating, reducer != nil, !streamReady
    else { return }
    streamReady = true
    emit(.streamState(sessionID: id, state: .live))
  }

  func handleConversationEvent(_ event: [String: JSONValue], sessionID: String) throws {
    guard watchedSessionID == sessionID else { return }
    recordConfigurationEvent(event, sessionID: sessionID)
    if isHydrating {
      guard bufferedEvents.count < 1_024 else {
        throw LocalServerClientError.transport(URLError.dataLengthExceedsMaximum.rawValue)
      }
      bufferedEvents.append(event)
    }
    if reducer == nil {
      let summary =
        summaries[sessionID]
        ?? SessionSummary(id: sessionID, title: "Conversation", preview: "", isReadOnly: true)
      reducer = LiveConversationReducer(
        snapshot: ConversationSnapshot(revision: revision, session: summary, messages: []))
    }
    try reduceEvent(event, sessionID: sessionID)
  }

  private func reduceEvent(_ event: [String: JSONValue], sessionID: String) throws {
    guard var current = reducer else { return }
    let effects = try current.apply(event)
    reducer = current
    emitEffects(effects, sessionID: sessionID)
    if effects.changed { publishSnapshot() }
    if effects.reconcile { beginHydration(sessionID: sessionID, generation: streamGeneration) }
  }

  func recordConfigurationEvent(_ event: [String: JSONValue], sessionID: String) {
    if let id = event["conversation_id"]?.string, id != sessionID { return }
    switch event["type"]?.string {
    case "session.model", "session.reasoning_effort", "session.model_options",
      "session.agent_changed",
      "session.status", "response.created", "response.in_progress", "response.queued",
      "response.elicitation_request", "response.elicitation_resolved", "response.completed",
      "response.failed", "response.incomplete", "response.cancelled", "session.interrupted":
      configurationEpochs[sessionID, default: 0] &+= 1
    default: break
    }
  }

  func recordConfigurationSummary(_ summary: SessionSummary) -> SessionSummary {
    let previous = summaries[summary.id]
    if previous?.configuration != summary.configuration || previous?.status != summary.status
      || previous?.isReadOnly != summary.isReadOnly || previous?.isArchived != summary.isArchived
    {
      configurationEpochs[summary.id, default: 0] &+= 1
    }
    configurationRevision &+= 1
    var stamped = summary
    stamped.configurationRevision = configurationRevision
    return stamped
  }

  func cacheSummary(_ summary: SessionSummary) {
    summaries[summary.id] = summary
    if reducer?.snapshot.id == summary.id { reducer?.snapshot.session = summary }
  }

  private func emitEffects(_ effects: LiveEventEffects, sessionID: String) {
    if let environment = effects.changedFilesEnvironment {
      invalidateChangedFiles(sessionID: sessionID, environmentID: environment)
    }
    if let itemID = effects.consumedItemID {
      emit(
        .inputConsumed(sessionID: sessionID, itemID: itemID, pendingID: effects.consumedPendingID))
    }
    if let error = effects.error { emit(.conversationError(sessionID: sessionID, message: error)) }
  }

  func invalidateChangedFiles(sessionID: String, environmentID: String) {
    guard watchedSessionID == sessionID else { return }
    changedFileEpochs[environmentID, default: 0] &+= 1
    guard changedFileTasks[environmentID] == nil else { return }
    let generation = streamGeneration
    changedFileTasks[environmentID] = Task { [weak self] in
      await self?.loadChangedFiles(
        sessionID: sessionID, environmentID: environmentID, generation: generation)
    }
  }

  private func loadChangedFiles(sessionID: String, environmentID: String, generation: UUID) async {
    defer {
      if generation == streamGeneration { changedFileTasks[environmentID] = nil }
    }
    while generation == streamGeneration && !Task.isCancelled {
      let epoch = changedFileEpochs[environmentID]
      let result: JSONValue
      do {
        try validateIdentifier(sessionID)
        try validateIdentifier(environmentID)
        result = try await get(
          path: "/v1/sessions/\(sessionID)/resources/environments/\(environmentID)/changes")
      } catch {
        result = .object([
          "error": .string("Changed files unavailable: \(error.localizedDescription)")
        ])
      }
      guard generation == streamGeneration, !Task.isCancelled, watchedSessionID == sessionID else {
        return
      }
      if epoch != changedFileEpochs[environmentID] { continue }
      var state = reducer?.snapshot.eventState ?? SessionEventState()
      let entry: JSONValue = result.array.map { .object(["entries": .array($0)]) } ?? result
      state.updateRecord("changed_files", id: environmentID, value: entry)
      reducer?.snapshot.eventState = state
      publishSnapshot()
      return
    }
  }

  private func runSessionList(generation: UUID) async {
    var attempt = 0
    while !Task.isCancelled && generation == listGeneration {
      do {
        let outgoing = try request(path: "/v1/sessions/updates", webSocket: true)
        let socket = streamingSession.webSocketTask(with: outgoing)
        socket.maximumMessageSize = 8 * 1_024 * 1_024
        listSocket = socket
        socket.resume()
        try await sendWatchSet(socket)
        while !Task.isCancelled && generation == listGeneration {
          let message = try await socket.receive()
          guard generation == listGeneration else { return }
          let data: Data
          switch message {
          case .data(let value): data = value
          case .string(let value): data = Data(value.utf8)
          @unknown default: continue
          }
          try await handleListMessage(data)
          attempt = 0
        }
      } catch {
        guard generation == listGeneration, !Task.isCancelled else { return }
        let error = streamFailure(error, response: listSocket?.response as? HTTPURLResponse)
        if error as? LocalServerClientError == .unauthorized {
          authenticationFailed()
          return
        }
        listSocket?.cancel(with: .goingAway, reason: nil)
        listSocket = nil
        if !shouldReconnect(error) {
          emit(.listState(.failed(error.localizedDescription)))
          return
        }
        emit(.listState(.reconnecting))
        emit(.inventoryInvalidated)
        attempt += 1
        do { try await Task.sleep(nanoseconds: retryDelay(attempt)) } catch { return }
      }
    }
  }

  private func sendWatchSet(_ socket: URLSessionWebSocketTask) async throws {
    let frame: JSONValue = .object([
      "type": .string("watch"), "session_ids": .array(watchedIDs.map(JSONValue.string)),
    ])
    let data = try JSONEncoder().encode(frame)
    try await socket.send(.string(String(decoding: data, as: UTF8.self)))
  }

  func handleListMessage(_ data: Data) async throws {
    let frame = try JSONDecoder().decode(SessionListFrame.self, from: data)
    switch frame.type {
    case "snapshot", "changed":
      guard let items = frame.items else { throw LocalServerClientError.malformedResponse }
      var changed: [SessionSummary] = []
      var discovery = false
      var hydrateSelected = false
      for wire in items {
        let summary = recordConfigurationSummary(try wire.summary(previous: summaries[wire.id]))
        cacheSummary(summary)
        changed.append(summary)
        if wire.id == watchedSessionID, !wire.hasConfigurationIdentity {
          hydrateSelected = true
        }
        if !watchedIDs.contains(summary.id) {
          watchedIDs.append(summary.id)
          discovery = true
        }
      }
      emit(.sessionsChanged(changed))
      emit(.inventoryInvalidated)
      // Sparse changes and reconnect snapshots invalidate the open detail snapshot.
      if hydrateSelected, streamDataTask != nil, let selected = watchedSessionID {
        beginHydration(sessionID: selected, generation: streamGeneration)
      }
      if frame.type == "snapshot" { emit(.listState(.live)) }
      if discovery {
        guard watchedIDs.count <= 500 else { throw LocalServerClientError.watchLimitExceeded }
        if let socket = listSocket { try await sendWatchSet(socket) }
      }
    case "removed":
      let ids = frame.ids ?? []
      for id in ids {
        configurationEpochs[id, default: 0] &+= 1
        summaries.removeValue(forKey: id)
      }
      watchedIDs.removeAll { ids.contains($0) }
      emit(.sessionsRemoved(ids))
      emit(.inventoryInvalidated)
      if let selected = watchedSessionID, ids.contains(selected) { stopWatching() }
    case "heartbeat": break
    default: break
    }
  }

  private func validateStreamResponse(_ response: URLResponse, request: URLRequest) throws {
    guard let http = response as? HTTPURLResponse else {
      throw LocalServerClientError.malformedResponse
    }
    guard http.url == request.url else { throw LocalServerClientError.redirectNotAllowed }
    switch http.statusCode {
    case 200:
      guard http.mimeType == "text/event-stream" else {
        throw LocalServerClientError.malformedResponse
      }
    case 300...399: throw LocalServerClientError.redirectNotAllowed
    case 401: throw LocalServerClientError.unauthorized
    case 403: throw LocalServerClientError.forbidden
    default: throw LocalServerClientError.httpStatus(http.statusCode)
    }
  }

  func streamFailure(_ error: Error, response: HTTPURLResponse? = nil) -> Error {
    if let code = response?.statusCode {
      switch code {
      case 300...399: return LocalServerClientError.redirectNotAllowed
      case 401: return LocalServerClientError.unauthorized
      case 403: return LocalServerClientError.forbidden
      case 400...599: return LocalServerClientError.httpStatus(code)
      default: break
      }
    }
    if let error = error as? URLError,
      [.userAuthenticationRequired, .userCancelledAuthentication].contains(error.code)
    {
      return LocalServerClientError.unauthorized
    }
    return error
  }

  func shouldReconnect(_ error: Error) -> Bool {
    if error is CancellationError { return false }
    if let error = error as? LocalServerClientError {
      switch error {
      case .transport: return true
      case .httpStatus(let code): return code == 429 || code >= 500
      default: return false
      }
    }
    if let error = error as? URLError {
      return ![
        .cancelled, .userAuthenticationRequired, .userCancelledAuthentication, .badURL,
        .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
        .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
        .clientCertificateRejected, .clientCertificateRequired,
      ].contains(error.code)
    }
    return false
  }

  private func retryDelay(_ attempt: Int) -> UInt64 {
    UInt64(min(8.0, 0.25 * pow(2, Double(min(attempt - 1, 6)))) * 1_000_000_000)
  }
}

private struct SessionListFrame: Decodable {
  let type: String
  let items: [SessionWire]?
  let ids: [String]?
}
