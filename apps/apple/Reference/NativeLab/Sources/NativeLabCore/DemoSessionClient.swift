import Foundation

public actor DemoSessionClient: SessionClient {
  private struct ActiveReply {
    let generation: Int
    let messageID: String
    let task: Task<Void, Never>
  }

  private static let replyText = """
    Got it. This is a sample reply from the offline demo. Your message stayed in this \
    conversation. You can try another message or create a new session.
    """

  private let responseDelayNanoseconds: UInt64
  private var snapshots: [String: ConversationSnapshot]
  private var sessionOrder: [String]
  private var continuations: [UUID: AsyncStream<ConversationSnapshot>.Continuation] = [:]
  private var activeReplies: [String: ActiveReply] = [:]
  private var nextGeneration = 0

  var activeSubscriptionCount: Int { continuations.count }

  public init(
    responseDelayNanoseconds: UInt64 = 80_000_000,
    initialSnapshots: [ConversationSnapshot] = DemoFixtures.snapshots
  ) {
    self.responseDelayNanoseconds = responseDelayNanoseconds
    let recovered = LocalWorkspace(snapshots: initialSnapshots).recoveringInterruptedReplies()
    snapshots = Dictionary(
      recovered.snapshots.map { original in
        var snapshot = original
        if snapshot.session.configuration == nil {
          snapshot.session.configuration = .demo
          snapshot.revision += 1
        }
        return (snapshot.id, snapshot)
      }, uniquingKeysWith: { _, last in last })
    sessionOrder = recovered.snapshots.map(\.id)
  }

  deinit {
    for reply in activeReplies.values { reply.task.cancel() }
    for continuation in continuations.values { continuation.finish() }
  }

  public func sessions() async throws -> [SessionSummary] {
    sessionOrder.compactMap { snapshots[$0]?.session }
  }

  public func configure(
    sessionID: String, edit: ConfigurationEdit, target: HarnessChoice? = nil
  ) async throws -> ConversationSnapshot {
    guard var snapshot = snapshots[sessionID] else { throw SessionClientError.sessionNotFound }
    if snapshot.session.isReadOnly { throw SessionClientError.readOnly }
    if snapshot.session.isArchived { throw SessionClientError.archived }
    if snapshot.session.status != .idle { throw SessionClientError.busy }
    var current = snapshot.session.configuration ?? .demo
    try edit.validate(against: current)
    if let target {
      if let reason = ConfigurationCatalog.demo.unavailableReason(for: target, current: current) {
        throw ConfigurationError.unavailable(reason)
      }
      current.agentID = target.id
      current.harness = target.harness
      current.wrapper =
        target.harness == "codex-native" ? "codex-native-ui" : "claude-code-native-ui"
      current.modelOverride = nil
      current.effort = nil
      snapshot.session.agentName = target.name
    } else {
      current.modelOverride = edit.model
      current.effort = edit.effort
    }
    snapshot.session.configuration = current
    snapshot.revision += 1
    publish(snapshot)
    return snapshot
  }

  public func conversation(id: String) async throws -> ConversationSnapshot {
    guard let snapshot = snapshots[id] else { throw SessionClientError.sessionNotFound }
    return snapshot
  }

  public func updates() async -> AsyncStream<ConversationSnapshot> {
    let subscriptionID = UUID()
    return AsyncStream { continuation in
      continuation.onTermination = { [weak self] _ in
        Task { await self?.removeSubscription(subscriptionID) }
      }
      continuations[subscriptionID] = continuation
      for sessionID in sessionOrder {
        if let snapshot = snapshots[sessionID] { continuation.yield(snapshot) }
      }
    }
  }

  public func send(_ text: String, to sessionID: String) async throws {
    guard var snapshot = snapshots[sessionID] else { throw SessionClientError.sessionNotFound }
    guard !snapshot.session.isReadOnly else { throw SessionClientError.readOnly }
    guard !snapshot.session.isArchived else { throw SessionClientError.archived }
    let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !message.isEmpty else { throw SessionClientError.emptyMessage }
    guard snapshot.pendingDecisions.isEmpty else { throw SessionClientError.needsDecision }
    guard activeReplies[sessionID] == nil else { throw SessionClientError.busy }

    nextGeneration += 1
    let generation = nextGeneration
    let replyID = "\(sessionID)-reply-\(UUID().uuidString)"
    snapshot.messages.append(
      ConversationMessage(id: "\(sessionID)-user-\(UUID().uuidString)", role: .user, text: message)
    )
    snapshot.messages.append(
      ConversationMessage(id: replyID, role: .assistant, text: "", isStreaming: true)
    )
    snapshot.session.status = .running
    snapshot.session.preview = message
    snapshot.revision += 1
    publish(snapshot)

    let delay = responseDelayNanoseconds
    let task = Task.detached { [weak self] in
      for word in Self.replyText.split(separator: " ") {
        do {
          try await Task.sleep(nanoseconds: delay)
        } catch {
          return
        }
        guard !Task.isCancelled else { return }
        guard await self?.appendWord(String(word), to: sessionID, generation: generation) == true
        else { return }
      }
      await self?.finishReply(sessionID: sessionID, generation: generation)
    }
    activeReplies[sessionID] = ActiveReply(
      generation: generation, messageID: replyID, task: task
    )
  }

  public func interrupt(sessionID: String) async throws {
    guard var snapshot = snapshots[sessionID] else { throw SessionClientError.sessionNotFound }
    guard !snapshot.session.isReadOnly else { throw SessionClientError.readOnly }
    guard let reply = activeReplies.removeValue(forKey: sessionID) else { return }
    reply.task.cancel()
    if let index = snapshot.messages.firstIndex(where: { $0.id == reply.messageID }) {
      let partialText = snapshot.messages[index].text
      snapshot.messages[index].text =
        partialText.isEmpty ? "Reply stopped." : partialText + "\n\nReply stopped."
      snapshot.messages[index].isStreaming = false
      snapshot.session.preview = snapshot.messages[index].text
    }
    snapshot.session.status = .idle
    snapshot.revision += 1
    publish(snapshot)
    await reply.task.value
  }

  public func resolve(
    decisionID: String, sessionID: String, response: DecisionResponse
  ) async throws {
    guard var snapshot = snapshots[sessionID] else { throw SessionClientError.sessionNotFound }
    guard !snapshot.session.isReadOnly else { throw SessionClientError.readOnly }
    guard let index = snapshot.decisions.firstIndex(where: { $0.id == decisionID }) else {
      throw SessionClientError.decisionNotFound
    }
    let decision = snapshot.decisions[index]
    guard decision.targetSessionID == sessionID else { throw SessionClientError.invalidDecision }
    guard decision.response == nil else { throw SessionClientError.decisionAlreadyResolved }

    let preview: String
    switch response {
    case .approve
    where decision.options.isEmpty && decision.form == nil && decision.externalURL == nil:
      preview = "Sample design approved."
    case .decline where decision.options.isEmpty:
      preview = "Sample design declined."
    case .answer(let answer) where decision.options.contains(answer):
      preview = "Selected: \(answer)"
    case .form(let values)
    where decision.form?.validationError(values: values) == nil && decision.form != nil:
      preview = "Sample form submitted."
    case .approveAllEdits where decision.allowAllEdits == true:
      preview = "Sample edits approved."
    case .approveRemembering where decision.rememberLabel != nil:
      preview = "Sample permission remembered."
    case .declineWithFeedback(let feedback)
    where decision.isPlanReview == true && !feedback.isEmpty:
      preview = "Plan feedback submitted."
    case .approveCommandPolicy(let amendment)
    where !amendment.isEmpty && amendment == decision.execPolicyAmendment:
      preview = "Sample command policy approved."
    default:
      throw SessionClientError.invalidDecision
    }

    snapshot.decisions[index].response = response
    snapshot.session.status = snapshot.pendingDecisions.isEmpty ? .idle : .needsResponse
    snapshot.session.preview = preview
    snapshot.revision += 1
    publish(snapshot)
  }

  public func createSession(title: String) async throws -> ConversationSnapshot {
    let sessionID = "demo-session-\(UUID().uuidString)"
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let snapshot = ConversationSnapshot(
      revision: 1,
      session: SessionSummary(
        id: sessionID, title: trimmedTitle.isEmpty ? "New conversation" : trimmedTitle,
        preview: "Ready for your first message.", configuration: .demo
      ),
      messages: []
    )
    sessionOrder.insert(sessionID, at: 0)
    publish(snapshot, updatesActivity: false)
    return snapshot
  }

  public func editSession(_ sessionID: String, change: SessionChange) async throws {
    guard var snapshot = snapshots[sessionID] else { throw SessionClientError.sessionNotFound }
    guard !snapshot.session.isReadOnly else { throw SessionClientError.readOnly }
    switch change {
    case .title(let name):
      let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !title.isEmpty, title.count <= 120 else { throw SessionClientError.invalidTitle }
      snapshot.session.title = title
    case .pinned(let pinned): snapshot.session.isPinned = pinned
    case .archived(let archived): snapshot.session.isArchived = archived
    }
    snapshot.revision += 1
    publish(snapshot, updatesActivity: false)
  }

  private func appendWord(_ word: String, to sessionID: String, generation: Int) -> Bool {
    guard let reply = activeReplies[sessionID], reply.generation == generation,
      var snapshot = snapshots[sessionID],
      let index = snapshot.messages.firstIndex(where: { $0.id == reply.messageID }),
      snapshot.messages[index].isStreaming
    else { return false }

    if !snapshot.messages[index].text.isEmpty { snapshot.messages[index].text += " " }
    snapshot.messages[index].text += word
    snapshot.session.preview = snapshot.messages[index].text
    snapshot.revision += 1
    publish(snapshot)
    return true
  }

  private func finishReply(sessionID: String, generation: Int) {
    guard let reply = activeReplies[sessionID], reply.generation == generation,
      var snapshot = snapshots[sessionID],
      let index = snapshot.messages.firstIndex(where: { $0.id == reply.messageID })
    else { return }

    activeReplies.removeValue(forKey: sessionID)
    snapshot.messages[index].isStreaming = false
    snapshot.session.status = .idle
    snapshot.revision += 1
    publish(snapshot)
  }

  private func publish(_ value: ConversationSnapshot, updatesActivity: Bool = true) {
    var snapshot = value
    if updatesActivity { snapshot.session.updatedAt = Date() }
    snapshots[snapshot.id] = snapshot
    for continuation in continuations.values { continuation.yield(snapshot) }
  }

  private func removeSubscription(_ id: UUID) {
    continuations.removeValue(forKey: id)
  }
}
