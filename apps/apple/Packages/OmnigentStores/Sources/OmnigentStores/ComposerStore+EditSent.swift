import Foundation
import OmnigentCoreFFI

/// Edit and resend (the web's `useEditSentMessage`): a sent message's text and `@` paths go
/// back into the composer to revise and send as a new message. The transcript is unchanged, the
/// original keeps its attachments, and a draft in progress is replaced only once the user agrees.
extension ComposerStore {
  /// Whether the composer holds something a loaded message would replace: text, quotes, `@`
  /// paths or staged files.
  public var hasDraft: Bool {
    !draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !mentions.isEmpty
      || (!isSending && !attachments.items.isEmpty)
  }

  /// Puts `text`, a sent message as the transcript shows it, in the composer. With a draft
  /// there, it waits in ``pendingEdit`` for ``replaceDraftWithEdit()`` or
  /// ``keepDraftOverEdit()``.
  /// - Parameter text: The sent message, with its `@` marker lines.
  public func editSentMessage(_ text: String) {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    if hasDraft {
      pendingEdit = text
    } else {
      loadSentMessage(text)
    }
  }

  /// Replaces the draft, attachments included, with the waiting sent message.
  public func replaceDraftWithEdit() {
    guard let text = pendingEdit else { return }
    pendingEdit = nil
    loadSentMessage(text)
  }

  /// Keeps the draft; the waiting sent message is dropped.
  public func keepDraftOverEdit() {
    pendingEdit = nil
  }

  private func loadSentMessage(_ sent: String) {
    let recalled = recallSentMessage(text: sent)
    // Files staged for the draft go; one already sending belongs to that message.
    if !isSending {
      for item in attachments.items { removeAttachment(item.id) }
    }
    commandNotice = nil
    isRestoring = true
    quotes = []
    mentions = recalled.mentions
    text = recalled.text
    isRestoring = false
    draftDidChange()
    editLoads += 1
  }
}
