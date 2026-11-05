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
      guard text != oldValue else { return }
      let nonBlank = Self.isNonBlank(text)
      if nonBlank != hasDraft {
        hasDraft = nonBlank
        draftChanged?(nonBlank)
      }
      draftStored?(text)
      mentionTextChanged()
      guard !applyingCoreText else { return }
      do {
        try core.updateComposer(sessionId: sessionID, text: text)
      } catch {
        lastError = coreError(error)
      }
    }
  }
  /// The draft holds more than whitespace. It changes only when that flips, so a view that
  /// needs to know whether there is something to send does not re-render on every keystroke.
  public private(set) var hasDraft = false
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
  /// What the server offers for `/` commands, once ``loadSkills()`` read it.
  public internal(set) var slashOptions = SlashOptions(serverClears: false) {
    didSet { if slashOptions != oldValue { refreshRules() } }
  }
  /// Bumped by `/permissions`: the composer opens its approval-mode picker.
  public internal(set) var approvalPickerRequests = 0
  /// The core's verdicts on the configuration, computed when it changes rather than on every
  /// read, so views that redraw while a reply streams make no core calls.
  var rules = ConfigurationRules()
  /// Workspace paths matching the draft's `@` mention, for the `@` menu.
  public internal(set) var mentionCandidates: [String] = []
  /// Workspace paths tagged with `@`, shown as chips and sent as marker lines ahead of the text.
  public internal(set) var mentions: [String] = []
  /// Why the `@` menu has no results (the workspace search failed); `nil` otherwise.
  public internal(set) var mentionProblem: String?
  /// Finds workspace paths for an `@` query; `nil` turns mentions off.
  public var searchMentions: (@MainActor (String) async throws -> [String])?
  var mentionQuery: String?
  var mentionTask: Task<Void, Never>?
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
  @ObservationIgnored private var applyingCoreText = false
  /// Told when the draft becomes empty or not (the sidebar's draft marker).
  @ObservationIgnored var draftChanged: ((Bool) -> Void)?
  /// Told the new draft text, to keep it across launches.
  @ObservationIgnored var draftStored: ((String) -> Void)?
  /// What `/context`, `/mcp` and held sends read from the conversation.
  @ObservationIgnored var conversationFacts: (@MainActor () -> ConversationFacts?)?
  /// Retries messages held for the host while it already reads online.
  @ObservationIgnored var hostRecheck: Task<Void, Never>?

  init(sessionID: String, core: ClientCore) {
    self.sessionID = sessionID
    self.core = core
  }

  /// Whether a send could start now.
  public var canSend: Bool {
    !isSending && !isBlocked
      && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !attachments.items.isEmpty || !mentions.isEmpty)
  }

  func deliver(
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
    await loadSlashOptions()
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

  /// Whether `text` holds anything but whitespace and newlines; stops at the first such
  /// character instead of trimming the whole draft.
  /// - Parameter text: The draft.
  /// - Returns: Whether it is worth sending.
  nonisolated static func isNonBlank(_ text: String) -> Bool {
    text.unicodeScalars.contains { !CharacterSet.whitespacesAndNewlines.contains($0) }
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
  /// `/side`: fork a side chat and open it with `question` as its draft.
  case sideChat(question: String)
}
