public import Foundation
import OmnigentCoreFFI

/// The queue: messages held until the running turn ends, then sent oldest first. "Send now"
/// sends one into the running turn instead (steering, where the harness takes mid-turn input).
/// A queued message keeps the draft's uploaded files (held in the core) and `@` paths, as on the
/// web. Every send goes through the core's submission ledger, like a typed one, and is never
/// retried on its own.
extension ComposerStore {
  /// Queues the draft (text, quotes, uploaded files and `@` paths) to send after the running
  /// turn, and clears it. Files still uploading keep everything in the draft.
  public func queueDraft() {
    enqueueDraft()
  }

  /// Queues the draft and clears it.
  /// - Returns: The queued message's id, or `nil` when it stayed in the draft with the reason.
  @discardableResult
  func enqueueDraft() -> Int? {
    let message = draftMessage
    let extras: MessageQueue.Extras
    do {
      extras = try takeExtras()
    } catch {
      lastError = coreError(error)
      return nil
    }
    do {
      let queued = try queue.enqueue(message, extras: extras)
      clearDraft()
      lastError = nil
      return queued.id
    } catch {
      // Only a message with nothing to send is refused, so no files are left held.
      lastError = Self.queueError(error)
      return nil
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

  /// Removes a queued message and forgets its files.
  /// - Parameter id: The message.
  public func removeQueued(_ id: Int) {
    let holdID = queue.items.first { $0.id == id }?.extras.holdID
    do {
      try queue.remove(id)
    } catch {
      lastError = Self.queueError(error)
      return
    }
    discardHeldFiles(holdID)
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
    if await deliver(id) { await sendFollowUps() }
  }

  /// Takes the newest queued message out of the queue to edit it in the field (Up in an empty
  /// composer); its files and `@` paths go back to the draft. A message being sent stays.
  /// - Returns: Its text, or `nil` when nothing can be taken.
  public func takeLastQueued() -> String? {
    guard let last = queue.items.last, last.state != .sending,
      restoreHeldFiles(last.extras.holdID)
    else { return nil }
    queue.removeNewest()
    for path in last.extras.mentions { addMention(path) }
    return last.text
  }

  /// Sends every queued message now, oldest first, steering the running turn (⌘Return). Stops
  /// at the first that does not go out, so order is kept.
  public func sendAllQueuedNow() async {
    for item in queue.items where item.state == .queued {
      await deliver(item.id)
      guard queue.items.allSatisfy({ $0.id != item.id }) else { return }
    }
  }

  /// Sends the messages that were sent while another was in flight, oldest first, once it was
  /// accepted. Stops at the first that does not go out, so order is kept.
  func sendFollowUps() async {
    while !isSending, !isBlocked,
      let next = queue.items.first(where: { followUps.contains($0.id) }), next.state == .queued
    {
      guard await deliver(next.id) else { return }
    }
  }

  /// Sends the oldest queued message when no turn runs and nothing else is sending. Call it
  /// whenever the turn ends.
  /// - Parameter isRunning: A turn is running.
  public func drainQueue(isRunning: Bool) async {
    guard let next = queue.next(isRunning: isRunning, isBlocked: isSending || isBlocked)
    else { return }
    if await deliver(next.id) { await sendFollowUps() }
  }

  /// Takes the draft's uploaded files (into a core hold) and `@` paths for a queued message.
  func takeExtras() throws -> MessageQueue.Extras {
    let held = try core.holdAttachments(sessionId: sessionID)
    if held != nil { refreshAttachments() }
    return MessageQueue.Extras(
      holdID: held?.id,
      files: held?.items.map { MessageQueue.File(name: $0.filename, isImage: $0.isImage) } ?? [],
      mentions: mentions)
  }

  /// Puts a hold's files back in the draft. A failure is shown and leaves them held.
  /// - Returns: Whether the draft has them again (or there were none).
  func restoreHeldFiles(_ holdID: UInt64?) -> Bool {
    guard let holdID else { return true }
    do {
      try core.restoreHeldAttachments(sessionId: sessionID, hold: holdID)
    } catch {
      lastError = coreError(error)
      return false
    }
    refreshAttachments()
    return true
  }

  /// Forgets a hold's files. A failure is shown.
  func discardHeldFiles(_ holdID: UInt64?) {
    guard let holdID else { return }
    do {
      try core.discardHeldAttachments(sessionId: sessionID, hold: holdID)
    } catch {
      lastError = coreError(error)
    }
  }

  /// Sends a queued message through the ledger.
  /// - Returns: Whether the server accepted it.
  @discardableResult
  private func deliver(_ id: Int) async -> Bool {
    guard !isSending, !isBlocked else {
      lastError = .InvalidState(message: "Wait for the current send to finish.")
      return false
    }
    let message: MessageQueue.Item
    do {
      message = try queue.begin(id)
    } catch {
      lastError = Self.queueError(error)
      return false
    }
    isSending = true
    lastError = nil
    defer {
      isSending = false
      refreshBlocked()
    }
    let pendingRow = transcript?.showSending(
      message.text, attachments: message.extras.files.map(PendingMessages.attachment))
    do {
      let sent = try await core.sendQueuedMessage(
        sessionId: sessionID, text: message.text, hold: message.extras.holdID,
        harness: configuration?.harness, paths: message.extras.mentions)
      transcript?.messageAccepted(pendingRow, sent)
      setText(fromCore: sent.draft)
      queue.finish(id, failure: nil)
      followUps.remove(id)
      return true
    } catch {
      transcript?.messageNotSent(pendingRow)
      let failure = coreError(error)
      if failure.isHostOffline {
        queue.waitForHost(id)
        commandNotice = failure.message
        scheduleHostRecheck()
        return false
      }
      queue.finish(id, failure: Self.failureNote(failure))
      lastError = failure
      return false
    }
  }

  /// Why a message did not go out; an unclear send warns before a retry.
  static func failureNote(_ failure: CoreError) -> String {
    failure.isDeliveryUncertain
      ? "It may have been sent. Check the conversation before retrying." : failure.message
  }

  static func queueError(_ error: MessageQueue.Refusal) -> CoreError {
    switch error {
    case .empty: .InvalidState(message: "Type a message to queue.")
    case .missing: .InvalidState(message: "That message is no longer queued.")
    case .sending: .InvalidState(message: "That message is being sent.")
    }
  }
}
