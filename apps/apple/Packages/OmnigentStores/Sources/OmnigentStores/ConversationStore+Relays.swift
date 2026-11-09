import OmnigentCoreFFI

/// What the conversation learns from sends and the stream and tells the transcript or composer.
extension ConversationStore {
  /// Shows a message being sent until the server echoes it.
  /// - Parameters:
  ///   - text: The message.
  ///   - attachments: Its files.
  /// - Returns: Its row's id, or `nil` for a message with nothing to show.
  func showSending(_ text: String, attachments: [Attachment] = []) -> String? {
    let rowID = pendingMessages.add(text: text, attachments: attachments, transcript: rows)
    digestRows()
    return rowID
  }

  /// The server accepted the message on `rowID`. The echo may already have arrived.
  /// - Parameters:
  ///   - rowID: The message's row, from ``showSending(_:attachments:)``.
  ///   - sent: The acknowledgement.
  func messageAccepted(_ rowID: String?, _ sent: MessageSent) {
    guard let rowID else { return }
    pendingMessages.acknowledge(rowID, itemID: sent.itemId)
    retireEchoedMessages()
    digestRows()
  }

  /// The message on `rowID` did not go out; whoever sent it keeps its text.
  /// - Parameter rowID: The message's row, from ``showSending(_:attachments:)``.
  func messageNotSent(_ rowID: String?) {
    guard let rowID else { return }
    pendingMessages.withdraw(rowID)
    digestRows()
  }

  /// Tells the composer the mode the harness last reported, which its chip shows.
  func relayReportedMode() {
    let section = sections.first { $0.id == "approval" } ?? sections.first { $0.id == "permission" }
    composer.harnessReported(mode: section?.details.first { $0.id == "mode" }?.text)
  }
}
