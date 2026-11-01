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
  public private(set) var isSending = false
  /// A send is in flight or its outcome is uncertain and unreviewed.
  public private(set) var isBlocked = false
  /// The last failure.
  public private(set) var lastError: CoreError?
  /// The session's harness, model and effort, once ``loadConfiguration()`` read them.
  public internal(set) var configuration: SessionConfiguration?
  /// Their display labels.
  public internal(set) var configurationLabels: ConfigurationLabels?
  /// What the session may switch to, and the host's model preview.
  public internal(set) var configurationCatalog: ConfigurationCatalog?
  /// A configuration change is in flight.
  public internal(set) var isApplyingConfiguration = false
  /// The last configuration failure.
  public internal(set) var configurationError: CoreError?

  let sessionID: String
  let core: ClientCore
  private var applyingCoreText = false

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

  /// Sends the draft and the uploaded attachments.
  public func send() async {
    isSending = true
    lastError = nil
    defer {
      isSending = false
      refreshBlocked()
    }
    do {
      let sent = try await core.sendMessage(sessionId: sessionID, text: text)
      setText(fromCore: sent.draft)
      refreshAttachments()
    } catch {
      lastError = coreError(error)
      refreshAttachments()
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

  private func setText(fromCore value: String) {
    applyingCoreText = true
    text = value
    applyingCoreText = false
  }

  private func refreshAttachments() {
    do {
      attachments = try core.attachmentDraft(sessionId: sessionID)
    } catch {
      lastError = coreError(error)
    }
  }

  private func refreshBlocked() {
    do {
      isBlocked = try core.isSendBlocked(sessionId: sessionID)
    } catch {
      lastError = coreError(error)
    }
  }
}
