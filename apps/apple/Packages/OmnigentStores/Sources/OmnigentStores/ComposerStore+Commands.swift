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
  /// A turn is running.
  var isRunning: Bool
  /// The session's host reads connected.
  var hostOnline: Bool
  /// What the `/mcp` panel reads.
  var mcpSession = McpPanelStore.Session()
}

/// Sending: a message, or the slash command the core recognizes in the draft.
extension ComposerStore {
  /// Sends the draft and the uploaded attachments. A slash command does what the core says: a
  /// skill runs on the server, `/compact` and `/clear` use their controls, `/model` and
  /// `/effort` change the configuration, `/context` and `/help` show text, `/mcp` keeps its
  /// panel open,
  /// `/permissions` opens the approval-mode picker, `/rewind` opens ``rewindPicker``,
  /// `/goal <objective>` goes out as a message, and `/new`, `/side`, a bare `/goal` and the
  /// session a claude-sdk `/clear` continues in are left to the caller.
  /// - Returns: What the caller still has to do.
  @discardableResult
  public func send() async -> ComposerSendOutcome {
    switch slashAction() {
    case nil, .sendText:
      await deliverMessage()
    case .sendGoal(let message):
      // The objective goes out in its canonical `/goal …` form.
      text = message
      await deliverMessage()
    case .runSkill(let name, let arguments):
      await deliverCommand { core, session, text in
        try await core.runSkill(sessionId: session, text: text, name: name, arguments: arguments)
      }
    case .compact:
      await deliverCommand { core, session, text in
        try await core.compact(sessionId: session, text: text)
      }
    case .setModel(let model):
      text = ""
      await selectModel(model)
    case .setEffort(let effort):
      text = ""
      await selectEffort(effort)
    case .clear:
      if let successor = await clearContext() { return .openSession(successor) }
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
      // The draft stays, so its panel (``mcp``) stays open, as on the web.
      commandNotice = nil
    case .permissions:
      openApprovalPicker()
    case .show(let output):
      commandNotice = output
    case .goal:
      text = ""
      commandNotice = nil
      return .goal
    case .rewind:
      text = ""
      commandNotice = nil
      // The picker reads the prompts once it shows (``RewindPicker/load()``).
      rewindPicker = RewindPicker(sessionID: sessionID, core: core)
      return .rewind
    case .sendText, .sendGoal, .runSkill, .compact, .setModel, .setEffort, .clear:
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
      text: message,
      hasAttachments: !attachments.items.isEmpty || !mentions.isEmpty || !reviewComments.isEmpty,
      configuration: configuration,
      skills: skills, options: commandOptions)
  }

  /// The server's command options with this session's own: its Goal control.
  var commandOptions: SlashOptions {
    var options = slashOptions
    options.goal = offersGoal
    return options
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

  /// Runs `/clear`; returns the session a claude-sdk clear continues in.
  private func clearContext() async -> String? {
    guard !refusesDuringSend() else { return nil }
    let command = text
    text = ""
    commandNotice = nil
    do {
      return try await core.clearContext(sessionId: sessionID)
    } catch {
      if text.isEmpty { text = command }
      lastError = coreError(error)
      return nil
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
