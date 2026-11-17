import OmnigentCoreFFI

/// What the conversation learns from sends and the stream and tells the transcript or composer.
extension ConversationStore {
  /// The server can or cannot be reached while the rows show what this device saved.
  /// - Parameter offline: Whether it is offline.
  func offlineChanged(_ offline: Bool) {
    if offline != isOffline { isOffline = offline }
  }

  /// Shows a message being sent until the server echoes it, and an idle session working in the
  /// list until its next server row (the transcript's working state comes from the core).
  /// - Parameters:
  ///   - text: The message.
  ///   - attachments: Its files.
  /// - Returns: Its row's id, or `nil` for a message with nothing to show.
  func showSending(_ text: String, attachments: [Attachment] = []) -> String? {
    sendCount += 1
    let rowID = pendingMessages.add(text: text, attachments: attachments, transcript: rows)
    if let rowID, !isRunning { sendingListStatus[rowID] = listStatus.expect(.running) }
    digestRows()
    return rowID
  }

  /// A command the server runs (a skill, `/compact`) is being posted. It shows no row until the
  /// server echoes one, and is something the user sent all the same.
  func commandPosted() {
    sendCount += 1
  }

  /// The server accepted the message on `rowID`. The echo may already have arrived.
  /// - Parameters:
  ///   - rowID: The message's row, from ``showSending(_:attachments:)``.
  ///   - sent: The acknowledgement.
  func messageAccepted(_ rowID: String?, _ sent: MessageSent) {
    guard let rowID else { return }
    sendingListStatus[rowID] = nil
    pendingMessages.acknowledge(rowID, itemID: sent.itemId)
    retireEchoedMessages()
    digestRows()
  }

  /// The message on `rowID` did not go out; whoever sent it keeps its text.
  /// - Parameter rowID: The message's row, from ``showSending(_:attachments:)``.
  func messageNotSent(_ rowID: String?) {
    guard let rowID else { return }
    sendingListStatus.removeValue(forKey: rowID)?.withdraw()
    pendingMessages.withdraw(rowID)
    digestRows()
  }

  /// Tells the composer the mode the harness last reported, which its chip shows.
  func relayReportedMode() {
    let section = sections.first { $0.id == "approval" } ?? sections.first { $0.id == "permission" }
    composer.harnessReported(mode: section?.details.first { $0.id == "mode" }?.text)
  }
}
