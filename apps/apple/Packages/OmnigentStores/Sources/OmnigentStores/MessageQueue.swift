public import Foundation

/// Messages the user queued to send after the running turn, in send order: the composer's queue
/// state machine. A message is queued, then sending, then gone (sent) or failed. The queue drains
/// one message at a time, oldest first, only while nothing runs or sends; a failed message holds
/// its place until it is retried or removed, so order is never lost. A message the server refused
/// because the session's host is offline waits for the host ahead of the rest. A message keeps
/// the files and `@` paths it was queued with (the files are held in the core until it is sent).
public struct MessageQueue: Equatable, Sendable {
  /// Where a queued message stands.
  public enum State: Equatable, Sendable {
    /// Waiting for the turn to end.
    case queued
    /// Being sent.
    case sending
    /// Refused while the session's host was offline; sent once it is back.
    case waitingForHost
    /// Not delivered; the reason. Retried only by the user.
    case failed(String)
  }

  /// A file that goes with a queued message.
  public struct File: Equatable, Sendable {
    /// The file name.
    public let name: String
    /// An image rather than a document.
    public let isImage: Bool

    /// Creates a file.
    /// - Parameters:
    ///   - name: The file name.
    ///   - isImage: An image.
    public init(name: String, isImage: Bool) {
      self.name = name
      self.isImage = isImage
    }
  }

  /// What a message carries besides its text.
  public struct Extras: Equatable, Sendable {
    /// The core's hold of its files, or `nil` without files.
    public var holdID: UInt64?
    /// Its files, in order.
    public var files: [File] = []
    /// Workspace paths tagged with `@`, sent as marker lines ahead of the text.
    public var mentions: [String] = []

    /// Creates extras.
    /// - Parameters:
    ///   - holdID: The core's hold of the files.
    ///   - files: The files.
    ///   - mentions: The tagged paths.
    public init(holdID: UInt64? = nil, files: [File] = [], mentions: [String] = []) {
      self.holdID = holdID
      self.files = files
      self.mentions = mentions
    }

    /// Nothing besides the text.
    public var isEmpty: Bool { holdID == nil && files.isEmpty && mentions.isEmpty }
  }

  /// One queued message.
  public struct Item: Equatable, Sendable, Identifiable {
    /// Stable id.
    public let id: Int
    /// The text; empty when the files or paths are the message.
    public internal(set) var text: String
    /// Where it stands.
    public internal(set) var state: State
    /// Its files and tagged paths.
    public internal(set) var extras: Extras
  }

  /// Why a queue operation was refused.
  public enum Refusal: Error, Equatable, Sendable {
    /// The text is blank and nothing else goes with it.
    case empty
    /// No message has that id.
    case missing
    /// The message is being sent.
    case sending
  }

  /// The messages, oldest first.
  public private(set) var items: [Item] = []
  private var lastID = 0

  /// Creates an empty queue.
  public init() {
    // Empty.
  }

  /// Whether nothing is queued.
  public var isEmpty: Bool { items.isEmpty }

  /// A message is being sent.
  public var isSending: Bool { items.contains { $0.state == .sending } }

  /// Appends `text` with `extras`.
  /// - Parameters:
  ///   - text: The message.
  ///   - extras: Its files and tagged paths.
  /// - Returns: The new message.
  /// - Throws: ``Refusal/empty`` for blank text without extras.
  @discardableResult
  public mutating func enqueue(_ text: String, extras: Extras = Extras()) throws(Refusal) -> Item {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty || !extras.isEmpty else { throw .empty }
    let item = make(trimmed, extras: extras, state: .queued)
    items.append(item)
    return item
  }

  private mutating func make(_ text: String, extras: Extras, state: State) -> Item {
    lastID += 1
    return Item(id: lastID, text: text, state: state, extras: extras)
  }

  /// Replaces a message's text. A failed message becomes queued again.
  /// - Parameters:
  ///   - id: The message.
  ///   - text: The new text.
  /// - Throws: ``Refusal`` when missing, sending, or blank without extras.
  public mutating func edit(_ id: Int, text: String) throws(Refusal) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let index = try index(of: id)
    guard !trimmed.isEmpty || !items[index].extras.isEmpty else { throw .empty }
    guard items[index].state != .sending else { throw .sending }
    items[index].text = trimmed
    if items[index].state != .waitingForHost { items[index].state = .queued }
  }

  /// Removes a message.
  /// - Parameter id: The message.
  /// - Throws: ``Refusal`` when missing or sending.
  public mutating func remove(_ id: Int) throws(Refusal) {
    let index = try index(of: id)
    guard items[index].state != .sending else { throw .sending }
    items.remove(at: index)
  }

  /// Removes the newest message, which the caller found is not being sent.
  mutating func removeNewest() {
    _ = items.popLast()
  }

  /// Moves messages, as `List.onMove` reports it.
  /// - Parameters:
  ///   - offsets: The messages to move.
  ///   - destination: Where to.
  public mutating func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
    let moving = offsets.sorted().filter { items.indices.contains($0) }.map { items[$0] }
    let before = offsets.filter { $0 < destination }.count
    items.removeAll { item in moving.contains { $0.id == item.id } }
    items.insert(contentsOf: moving, at: min(max(destination - before, 0), items.count))
  }

  /// The message to send next, or `nil`: the oldest one, when it is queued, nothing runs and
  /// nothing else is sending.
  /// - Parameters:
  ///   - isRunning: A turn is running.
  ///   - isBlocked: The composer cannot send now (a send in flight, an unreviewed uncertain
  ///     send, staged attachments).
  /// - Returns: The message.
  public func next(isRunning: Bool, isBlocked: Bool) -> Item? {
    guard !isRunning, !isBlocked, !isSending, let first = items.first, first.state == .queued
    else { return nil }
    return first
  }

  /// Whether a message waits for the session's host.
  public var isHoldingForHost: Bool { items.contains { $0.state == .waitingForHost } }

  /// Holds `text`, refused while the host was offline, ahead of the messages queued after it.
  /// The server was asked to take it, so it has something to send.
  /// - Parameters:
  ///   - text: The message.
  ///   - extras: Its files and tagged paths.
  public mutating func hold(_ text: String, extras: Extras = Extras()) {
    let item = make(
      text.trimmingCharacters(in: .whitespacesAndNewlines), extras: extras,
      state: .waitingForHost)
    let index = items.firstIndex { $0.state != .waitingForHost } ?? items.endIndex
    items.insert(item, at: index)
  }

  /// Ends a send the server refused because the host is offline: the message waits for it.
  /// - Parameter id: The message.
  public mutating func waitForHost(_ id: Int) {
    guard let index = items.firstIndex(where: { $0.id == id }) else { return }
    items[index].state = .waitingForHost
  }

  /// The host is back: held messages queue again, in place.
  public mutating func releaseHeld() {
    for index in items.indices where items[index].state == .waitingForHost {
      items[index].state = .queued
    }
  }

  /// Marks a message as sending (drain, Send now, or Retry).
  /// - Parameter id: The message.
  /// - Returns: The message.
  /// - Throws: ``Refusal`` when missing or already sending.
  public mutating func begin(_ id: Int) throws(Refusal) -> Item {
    let index = try index(of: id)
    guard items[index].state != .sending else { throw .sending }
    items[index].state = .sending
    return items[index]
  }

  /// Ends a send: a delivered message leaves the queue, a failed one keeps its place.
  /// - Parameters:
  ///   - id: The message.
  ///   - failure: Why it failed, or `nil` when delivered.
  public mutating func finish(_ id: Int, failure: String?) {
    guard let index = items.firstIndex(where: { $0.id == id }) else { return }
    if let failure {
      items[index].state = .failed(failure)
    } else {
      items.remove(at: index)
    }
  }

  private func index(of id: Int) throws(Refusal) -> Int {
    guard let index = items.firstIndex(where: { $0.id == id }) else { throw .missing }
    return index
  }
}
