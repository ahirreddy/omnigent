public import Foundation
public import Observation
public import OmnigentCoreFFI

/// The composer of one conversation: draft text, attachments, and sending through the core's
/// submission ledger. An uncertain send blocks the next one until the user reviews it.
@Observable
public final class ComposerStore {
  /// The draft text. Changes are recorded in the core, so a late send result keeps newer text.
  public var text = "" {
    didSet {
      let hasDraft = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      if hasDraft != !oldValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        draftChanged?(hasDraft)
      }
      guard text != oldValue, !applyingCoreText else { return }
      do {
        try core.updateComposer(sessionId: sessionID, text: text)
      } catch {
        lastError = coreError(error)
      }
    }
  }
  /// Staged attachments.
  public private(set) var attachments = AttachmentDraft(items: [], selectionError: nil)
  /// A send is in flight.
  public internal(set) var isSending = false
  /// A send is in flight or its outcome is uncertain and unreviewed.
  public internal(set) var isBlocked = false
  /// The last failure.
  public internal(set) var lastError: CoreError?
  /// The session's harness, model and effort, once ``loadConfiguration()`` read them.
  public internal(set) var configuration: SessionConfiguration? {
    didSet { if configuration != oldValue { refreshRules() } }
  }
  /// Their display labels.
  public internal(set) var configurationLabels: ConfigurationLabels?
  /// What the session may switch to, and the host's model preview.
  public internal(set) var configurationCatalog: ConfigurationCatalog? {
    didSet { if configurationCatalog != oldValue { refreshRules() } }
  }
  /// The skills the session's host offers, once ``loadSkills()`` read them.
  public internal(set) var skills: [Skill] = [] {
    didSet { if skills != oldValue { refreshRules() } }
  }
  /// Why the skill list is missing or incomplete (a failed read, or sources the host could not
  /// read); `nil` when complete.
  public internal(set) var skillsProblem: String?
  /// The output of the last local command (`/help`, a usage line), until dismissed.
  public internal(set) var commandNotice: String?
  /// The core's verdicts on the configuration, computed when it changes rather than on every
  /// read, so views that redraw while a reply streams make no core calls.
  var rules = ConfigurationRules()
  /// A configuration change is in flight.
  public internal(set) var isApplyingConfiguration = false
  /// The last configuration failure.
  public internal(set) var configurationError: CoreError?
  /// Messages queued to send after the running turn.
  public internal(set) var queue = MessageQueue()
  /// The session's workspace path, from the last configuration read.
  public internal(set) var workspace: String?

  let sessionID: String
  let core: ClientCore
  private var applyingCoreText = false
  /// Told when the draft becomes empty or not (the sidebar's draft marker).
  @ObservationIgnored var draftChanged: ((Bool) -> Void)?

  init(sessionID: String, core: ClientCore) {
    self.sessionID = sessionID
    self.core = core
  }

  /// Whether a send could start now.
  public var canSend: Bool {
    !isSending && !isBlocked
      && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !attachments.items.isEmpty)
  }

  /// Sends the draft and the uploaded attachments. A slash command does what the core says:
  /// a skill runs on the server, `/compact` uses the compact control, `/model` and `/effort`
  /// change the configuration, `/help` shows text, and `/new` is left to the caller.
  /// - Returns: What the caller still has to do.
  @discardableResult
  public func send() async -> ComposerSendOutcome {
    switch slashAction() {
    case nil, .sendText:
      await deliver { core, session, text in
        try await core.sendMessage(sessionId: session, text: text)
      }
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
    case .newSession:
      text = ""
      return .newSession
    case .show(let output):
      commandNotice = output
    }
    return .handled
  }

  /// Hides ``commandNotice``.
  public func dismissCommandNotice() {
    commandNotice = nil
  }

  /// What sending the draft would do, when it is a command this session knows.
  func slashAction() -> SlashAction? {
    let trimmed = text.drop { $0.isWhitespace }
    guard trimmed.hasPrefix("/") || trimmed.hasPrefix("$"), let configuration else { return nil }
    return OmnigentCoreFFI.slashAction(
      text: text, hasAttachments: !attachments.items.isEmpty, configuration: configuration,
      skills: skills)
  }

  private func deliver(
    _ post: (ClientCore, String, String) async throws -> MessageSent
  ) async {
    isSending = true
    lastError = nil
    commandNotice = nil
    defer {
      isSending = false
      refreshBlocked()
    }
    do {
      let sent = try await post(core, sessionID, text)
      setText(fromCore: sent.draft)
      refreshAttachments()
    } catch {
      lastError = coreError(error)
      refreshAttachments()
    }
  }

  /// Reads the skills the session's host offers, for the `/` menu. A failure leaves the
  /// built-in commands and says why in ``skillsProblem``.
  public func loadSkills() async {
    do {
      let catalog = try await core.sessionSkills(sessionId: sessionID)
      if skills != catalog.skills { skills = catalog.skills }
      let problem =
        catalog.warnings.isEmpty
        ? nil : "Some skills could not be read: \(catalog.warnings.joined(separator: "; "))"
      if skillsProblem != problem { skillsProblem = problem }
    } catch {
      skillsProblem = "Skills are unavailable: \(coreError(error).message)"
    }
  }

  /// Stages a file.
  /// - Parameters:
  ///   - filename: The file name.
  ///   - mediaType: The declared media type, if any.
  ///   - data: The bytes.
  public func addAttachment(filename: String, mediaType: String?, data: Data) {
    do {
      _ = try core.addAttachment(
        sessionId: sessionID, filename: filename, mediaType: mediaType, data: data)
      lastError = nil
    } catch {
      lastError = coreError(error)
    }
    refreshAttachments()
  }

  /// Uploads a staged file.
  /// - Parameter id: The attachment id.
  public func upload(_ id: UInt64) async {
    do {
      try await core.uploadAttachment(sessionId: sessionID, itemId: id)
    } catch {
      lastError = coreError(error)
    }
    refreshAttachments()
  }

  /// Removes a staged file.
  /// - Parameter id: The attachment id.
  public func removeAttachment(_ id: UInt64) {
    do {
      try core.removeAttachment(sessionId: sessionID, itemId: id)
    } catch {
      lastError = coreError(error)
    }
    refreshAttachments()
  }

  /// The user reviewed an uncertain send; sending is allowed again.
  public func acknowledgeUncertainSend() {
    do {
      _ = try core.acknowledgeUncertainSend(sessionId: sessionID)
      lastError = nil
    } catch {
      lastError = coreError(error)
    }
    refreshBlocked()
  }

  func streamReady() {
    do {
      setText(fromCore: try core.composerText(sessionId: sessionID))
    } catch {
      lastError = coreError(error)
    }
    refreshAttachments()
    refreshBlocked()
  }

  func setText(fromCore value: String) {
    applyingCoreText = true
    text = value
    applyingCoreText = false
  }

  func refreshAttachments() {
    do {
      attachments = try core.attachmentDraft(sessionId: sessionID)
    } catch {
      lastError = coreError(error)
    }
  }

  func refreshBlocked() {
    do {
      isBlocked = try core.isSendBlocked(sessionId: sessionID)
    } catch {
      lastError = coreError(error)
    }
  }
}

/// What the caller still has to do after ``ComposerStore/send()``.
public enum ComposerSendOutcome: Sendable, Equatable {
  /// Nothing: the store sent, applied or showed it.
  case handled
  /// `/new`: open a blank session in the same project.
  case newSession
}
