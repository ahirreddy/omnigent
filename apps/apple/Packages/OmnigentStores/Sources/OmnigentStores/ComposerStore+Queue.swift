public import Foundation
import OmnigentCoreFFI

/// The queue: messages held until the running turn ends, then sent oldest first. "Send now"
/// sends one into the running turn instead (steering, where the harness takes mid-turn input).
/// Every send goes through the core's submission ledger, like a typed one, and is never retried
/// on its own.
extension ComposerStore {
  /// Queues the draft text to send after the running turn, and clears the draft. Attachments
  /// cannot be queued; they stay in the draft.
  public func queueDraft() {
    guard attachments.items.isEmpty else {
      lastError = .InvalidState(
        message: "Queued messages can't carry attachments. Steer now, or send after this turn.")
      return
    }
    do {
      try queue.enqueue(text)
      text = ""
      lastError = nil
    } catch {
      lastError = Self.queueError(error)
    }
  }

  /// Replaces a queued message's text.
  /// - Parameters:
  ///   - id: The message.
  ///   - text: The new text.
  public func editQueued(_ id: Int, text: String) {
    do {
      try queue.edit(id, text: text)
    } catch {
      lastError = Self.queueError(error)
    }
  }

  /// Removes a queued message.
  /// - Parameter id: The message.
  public func removeQueued(_ id: Int) {
    do {
      try queue.remove(id)
    } catch {
      lastError = Self.queueError(error)
    }
  }

  /// Reorders queued messages.
  /// - Parameters:
  ///   - offsets: The messages to move.
  ///   - destination: Where to.
  public func moveQueued(fromOffsets offsets: IndexSet, toOffset destination: Int) {
    queue.move(fromOffsets: offsets, toOffset: destination)
  }

  /// Sends a queued message now: into the running turn, or again after a failure.
  /// - Parameter id: The message.
  public func sendQueuedNow(_ id: Int) async {
    await deliver(id)
  }

  /// Sends the oldest queued message when no turn runs and nothing else is sending. Call it
  /// whenever the turn ends.
  /// - Parameter isRunning: A turn is running.
  public func drainQueue(isRunning: Bool) async {
    let blocked = isSending || isBlocked || !attachments.items.isEmpty
    guard let next = queue.next(isRunning: isRunning, isBlocked: blocked) else { return }
    await deliver(next.id)
  }

  private func deliver(_ id: Int) async {
    guard !isSending, !isBlocked else {
      lastError = .InvalidState(message: "Wait for the current send to finish.")
      return
    }
    guard attachments.items.isEmpty else {
      lastError = .InvalidState(
        message: "Send or remove the attached files first; they would go with this message.")
      return
    }
    let message: String
    do {
      message = try queue.begin(id)
    } catch {
      lastError = Self.queueError(error)
      return
    }
    isSending = true
    lastError = nil
    defer {
      isSending = false
      refreshBlocked()
    }
    do {
      let sent = try await core.sendMessage(sessionId: sessionID, text: message)
      setText(fromCore: sent.draft)
      queue.finish(id, failure: nil)
    } catch {
      let failure = coreError(error)
      queue.finish(
        id,
        failure: failure.isDeliveryUncertain
          ? "It may have been sent. Check the conversation before retrying." : failure.message)
      lastError = failure
    }
  }

  private static func queueError(_ error: MessageQueue.Refusal) -> CoreError {
    switch error {
    case .empty: .InvalidState(message: "Type a message to queue.")
    case .missing: .InvalidState(message: "That message is no longer queued.")
    case .sending: .InvalidState(message: "That message is being sent.")
    }
  }
}
