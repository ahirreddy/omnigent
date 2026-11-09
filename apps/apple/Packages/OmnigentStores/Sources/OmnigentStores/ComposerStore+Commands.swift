import Foundation
import OmnigentCoreFFI

/// What the composer reads from its conversation for `/context`, `/mcp` and held sends.
struct ConversationFacts: Equatable {
  /// Tokens in context, once a turn reported them.
  var tokensUsed: UInt64?
  /// The model's context window, when known.
  var contextWindow: UInt64?
  /// Transcript items.
  var items: Int
  /// The agent's MCP servers, once ``agentLoaded``.
  var mcpServers: [String]
  /// The agent's details were read.
  var agentLoaded: Bool
  /// A turn is running.
  var isRunning: Bool
  /// The session's host reads connected.
  var hostOnline: Bool
}

/// Sending: a message, or the slash command the core recognizes in the draft. A message the
/// server refuses because the session's host is offline waits in the queue for the host.
extension ComposerStore {
  /// Sends the draft and the uploaded attachments. A slash command does what the core says: a
  /// skill runs on the server, `/compact` and `/clear` use their controls, `/model` and
  /// `/effort` change the configuration, `/context`, `/mcp` and `/help` show text,
  /// `/permissions` opens the approval-mode picker, and `/new` and `/side` are left to the
  /// caller.
  /// - Returns: What the caller still has to do.
  @discardableResult
  public func send() async -> ComposerSendOutcome {
    switch slashAction() {
    case nil, .sendText:
      await deliverMessage()
    case .runSkill(let name, let arguments):
      await deliver { core, session, text in
        try await core.runSkill(sessionId: session, text: text, name: name, arguments: arguments)
      }
    case .compact:
      await deliver { core, session, text in
        try await core.compact(sessionId: session, text: text)
      }
    case .setModel(let model):
      text = ""
      await selectModel(model)
    case .setEffort(let effort):
      text = ""
      await selectEffort(effort)
    case .clear:
      await clearContext()
    case .some(let action):
      return runLocally(action)
    }
    return .handled
  }

  /// Hides ``commandNotice``.
  public func dismissCommandNotice() {
    commandNotice = nil
  }

  /// Puts `text` in another session's composer, for example a new side chat's question; that
  /// session's composer shows it when it opens.
  /// - Parameters:
  ///   - text: The draft.
  ///   - sessionID: The session.
  public func seedDraft(_ text: String, forSession sessionID: String) {
    do {
      try core.updateComposer(sessionId: sessionID, text: text)
    } catch {
      lastError = coreError(error)
    }
  }

  /// The host is back: messages held for it queue again and the queue drains.
  public func releaseHeldMessages() async {
    hostRecheck?.cancel()
    hostRecheck = nil
    guard queue.isHoldingForHost else { return }
    queue.releaseHeld()
    await drainQueue(isRunning: conversationFacts?()?.isRunning ?? false)
  }

  /// Runs a command that sends nothing, or leaves it to the caller.
  private func runLocally(_ action: SlashAction) -> ComposerSendOutcome {
    switch action {
    case .newSession:
      text = ""
      return .newSession
    case .sideChat(let question):
      return .sideChat(question: question)
    case .context:
      commandNotice = contextReport()
    case .mcp:
      let facts = conversationFacts?()
      commandNotice = mcpReport(servers: facts?.agentLoaded == true ? facts?.mcpServers : nil)
    case .permissions:
      openApprovalPicker()
    case .show(let output):
      commandNotice = output
    case .sendText, .runSkill, .compact, .setModel, .setEffort, .clear:
      break
    }
    return .handled
  }

  /// What sending the draft would do, when it is a command this session knows.
  func slashAction() -> SlashAction? {
    let message = draftMessage
    let trimmed = message.drop { $0.isWhitespace }
    guard trimmed.hasPrefix("/") || trimmed.hasPrefix("$"), let configuration else { return nil }
    return OmnigentCoreFFI.slashAction(
      text: message, hasAttachments: !attachments.items.isEmpty || !mentions.isEmpty,
      configuration: configuration,
      skills: skills, options: slashOptions)
  }

  /// Reads which server-backed commands to offer. A failure keeps them hidden and says why in
  /// ``skillsProblem`` (unless skills already failed).
  func loadSlashOptions() async {
    do {
      let options = try await core.slashOptions()
      if slashOptions != options { slashOptions = options }
    } catch {
      if skillsProblem == nil {
        skillsProblem = "Some commands are unavailable: \(coreError(error).message)"
      }
    }
  }

  /// The session's header says its host came online.
  func hostCameOnline() {
    guard queue.isHoldingForHost else { return }
    Task { await releaseHeldMessages() }
  }

  /// Retries held messages after ``hostRecheckDelay`` when the host already reads online;
  /// otherwise the header's next online report releases them.
  func scheduleHostRecheck() {
    guard conversationFacts?()?.hostOnline ?? false, hostRecheck == nil else { return }
    let delay = hostRecheckDelay
    hostRecheck = Task { [weak self] in
      do {
        try await Task.sleep(for: delay)
      } catch {
        // Released or replaced meanwhile.
        return
      }
      self?.hostRecheck = nil
      await self?.releaseHeldMessages()
    }
  }

  private func deliverMessage() async {
    let draft = draftMessage
    let (paths, harness) = (mentions, configuration?.harness)
    let pendingRow = transcript?.showSending(
      draft, attachments: attachments.items.map(PendingMessages.attachment))
    await deliver { [transcript] core, session, text in
      let sent: MessageSent
      if paths.isEmpty {
        sent = try await core.sendMessage(sessionId: session, text: text)
      } else {
        sent = try await core.sendMessageMentioning(
          sessionId: session, text: text, harness: harness, paths: paths)
      }
      transcript?.messageAccepted(pendingRow, sent)
      return sent
    }
    if lastError != nil { transcript?.messageNotSent(pendingRow) }
    if lastError == nil, !paths.isEmpty { mentions.removeAll { paths.contains($0) } }
    guard let failure = lastError, failure.isHostOffline else { return }
    let extras: MessageQueue.Extras
    do {
      extras = try takeExtras()
    } catch {
      // A file still uploading keeps the message in the draft, with the failure shown.
      return
    }
    do {
      try queue.hold(draft, extras: extras)
    } catch {
      // Only a message with nothing to send is refused, so no files are left held.
      lastError = Self.queueError(error)
      return
    }
    mentions = []
    lastError = nil
    commandNotice = failure.message
    if draftMessage == draft { clearDraft() }
    scheduleHostRecheck()
  }

  private func clearContext() async {
    let command = text
    text = ""
    commandNotice = nil
    do {
      try await core.clearContext(sessionId: sessionID)
    } catch {
      if text.isEmpty { text = command }
      lastError = coreError(error)
    }
  }

  private func contextReport() -> String {
    let facts = conversationFacts?()
    return OmnigentCoreFFI.contextReport(
      configuration: configuration, tokensUsed: facts?.tokensUsed,
      contextWindow: facts?.contextWindow, items: UInt64(facts?.items ?? 0))
  }

  /// The core offers this command only to a session whose menu has modes to switch to.
  private func openApprovalPicker() {
    text = ""
    commandNotice = nil
    approvalPickerRequests += 1
  }
}
