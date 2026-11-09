import Foundation
public import OmnigentCoreFFI

/// Messages this client sent that the server has not echoed yet, shown as rows until it does.
/// Each echo retires exactly one message, so sending the same text twice shows it twice.
public struct PendingMessages: Equatable, Sendable {
  /// One message waiting for its echo.
  struct Entry: Equatable, Sendable {
    let rowID: String
    let text: String
    let attachments: [Attachment]
    /// The user row last shown when this was sent: only a later row can be its echo.
    let precedingUserRowID: String?
    /// The persisted item, once the server acknowledged it.
    var itemID: String?
  }

  private(set) var entries: [Entry] = []
  /// Changes whenever the rows do, so a transcript following the revision notices.
  private(set) var generation: UInt64 = 0
  private var nextNumber = 0
  /// Echoes that already retired a message and can't retire another.
  private var claimedRowIDs: Set<String> = []

  /// Creates an empty list.
  public init() {}

  /// The rows to show after the transcript, oldest first.
  public var rows: [Row] {
    entries.map { entry in
      Row(
        id: entry.rowID, role: .user, text: entry.text, isStreaming: false, activity: nil,
        attachments: entry.attachments, callId: nil, responseId: nil, interrupted: false,
        author: nil, agent: nil, createdAt: nil, isEphemeral: true, isActivityOnly: false)
    }
  }

  /// Adds a message being sent, unless it has nothing to show.
  /// - Parameters:
  ///   - text: The message.
  ///   - attachments: Its files.
  ///   - transcript: The rows on screen now.
  /// - Returns: The new row's id, or `nil` for a message with no text or files.
  mutating func add(text: String, attachments: [Attachment], transcript: [Row]) -> String? {
    let trimmed = Self.comparable(text)
    guard !trimmed.isEmpty || !attachments.isEmpty else { return nil }
    nextNumber += 1
    let rowID = "\(LocalRowPrefix.pendingMessage)\(nextNumber)"
    entries.append(
      Entry(
        rowID: rowID, text: trimmed, attachments: attachments,
        precedingUserRowID: transcript.last { $0.role == .user }?.id))
    generation += 1
    return rowID
  }

  /// Records the persisted item the server acknowledged for a message.
  /// - Parameters:
  ///   - rowID: The message's row.
  ///   - itemID: The item, when the server persisted one.
  mutating func acknowledge(_ rowID: String, itemID: String?) {
    guard let index = entries.firstIndex(where: { $0.rowID == rowID }) else { return }
    entries[index].itemID = itemID
  }

  /// Removes a message that was not sent.
  /// - Parameter rowID: The message's row.
  mutating func withdraw(_ rowID: String) {
    let before = entries.count
    entries.removeAll { $0.rowID == rowID }
    if entries.count != before { generation += 1 }
  }

  /// Retires the messages `transcript` now holds: by item id, else by text on a user row newer
  /// than the message (a stream echo can beat the acknowledgement, and a native terminal has no
  /// item id to compare until it consumes the input).
  /// - Parameter transcript: The server's rows.
  mutating func retireEchoes(in transcript: [Row]) {
    guard !entries.isEmpty else { return }
    let before = entries.count
    let users = transcript.filter { $0.role == .user && !$0.isEphemeral }
    for row in users where !claimedRowIDs.contains(row.id) {
      if let index = entries.firstIndex(where: { $0.itemID == row.id }) {
        claimedRowIDs.insert(row.id)
        entries.remove(at: index)
      }
    }
    for (position, row) in users.enumerated() where !claimedRowIDs.contains(row.id) {
      let text = Self.comparable(row.text)
      let echoed = entries.firstIndex { entry in
        text.hasSuffix(entry.text) && Self.isNewer(position, than: entry, in: users)
      }
      if let echoed {
        claimedRowIDs.insert(row.id)
        entries.remove(at: echoed)
      }
    }
    if entries.count != before { generation += 1 }
  }

  /// A row above the one shown at send time, such as a page of older history, is no echo.
  private static func isNewer(_ position: Int, than entry: Entry, in users: [Row]) -> Bool {
    guard let preceding = entry.precedingUserRowID,
      let precedingPosition = users.firstIndex(where: { $0.id == preceding })
    else { return true }
    return position > precedingPosition
  }

  private static func comparable(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

/// Ids of rows that exist only in this client.
enum LocalRowPrefix {
  /// A sent message waiting for its echo. `live:` marks it as a preview a persisted item replaces.
  static let pendingMessage = "live:pending-message:"
}

extension PendingMessages {
  /// A file of a message being sent, by name only: its reference exists once it is persisted.
  static func attachment(id: String, name: String, mediaType: String?, isImage: Bool) -> Attachment
  {
    Attachment(
      id: id, kind: isImage ? .image : .file, title: name, reference: nil, mimeType: mediaType,
      isEmbedded: false)
  }

  static func attachment(_ file: DraftAttachment) -> Attachment {
    attachment(
      id: String(file.id), name: file.filename, mediaType: file.mediaType, isImage: file.isImage)
  }

  static func attachment(_ file: MessageQueue.File) -> Attachment {
    attachment(id: file.name, name: file.name, mediaType: nil, isImage: file.isImage)
  }

  static func attachment(_ file: PendingAttachment) -> Attachment {
    attachment(
      id: file.id.uuidString, name: file.filename, mediaType: file.mediaType,
      isImage: file.mediaType?.hasPrefix("image/") == true)
  }
}
