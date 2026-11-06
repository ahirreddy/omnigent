import Foundation

/// A message queued (or steering) while the agent works, with the files and `@` paths it was
/// queued with.
nonisolated public struct QueuedMessage: Hashable, Sendable, Identifiable {
  /// Its state.
  public enum State: Hashable, Sendable {
    /// Waiting for the turn to end.
    case queued
    /// Being sent.
    case sending
    /// "Waiting for host".
    case waitingForHost
    /// "Send failed".
    case failed(message: String)
  }

  /// A file that goes with it.
  public struct File: Hashable, Sendable {
    /// The file name.
    public var name: String
    /// An image.
    public var isImage: Bool

    /// Creates a file.
    /// - Parameters:
    ///   - name: The file name.
    ///   - isImage: An image.
    public init(name: String, isImage: Bool = false) {
      self.name = name
      self.isImage = isImage
    }
  }

  /// Stable id.
  public var id: String
  /// The text; empty when the files or paths are the message.
  public var text: String
  /// State.
  public var state: State
  /// Files sent with it.
  public var files: [File] = []
  /// Workspace paths tagged with `@`, sent ahead of the text.
  public var mentions: [String] = []

  /// Creates a queued message.
  /// - Parameters:
  ///   - id: Id.
  ///   - text: Text.
  ///   - state: State.
  ///   - files: Files sent with it.
  ///   - mentions: Tagged workspace paths.
  public init(
    id: String, text: String, state: State = .queued, files: [File] = [], mentions: [String] = []
  ) {
    self.id = id
    self.text = text
    self.state = state
    self.files = files
    self.mentions = mentions
  }
}

/// Transcript text the draft quotes (Reply), after the text typed before it (the web's reply
/// draft blocks).
nonisolated public struct ComposerQuote: Hashable, Sendable {
  /// The text typed before the quote; edited in its own field.
  public var before: String
  /// The quoted text.
  public var text: String

  /// Creates a quote.
  /// - Parameters:
  ///   - before: The text typed before it.
  ///   - text: The quoted text.
  public init(before: String = "", text: String) {
    self.before = before
    self.text = text
  }
}

/// What the draft's quote blocks can do. `nil` hides the control.
public struct ComposerQuoteActions {
  /// Removes quote `index` ("Remove quote").
  public var remove: (@MainActor (Int) -> Void)?
  /// Replaces the text typed before quote `index`.
  public var editLead: (@MainActor (Int, String) -> Void)?

  /// Creates actions.
  /// - Parameters:
  ///   - remove: Remove a quote.
  ///   - editLead: Edit the text before a quote.
  public init(
    remove: (@MainActor (Int) -> Void)? = nil, editLead: (@MainActor (Int, String) -> Void)? = nil
  ) {
    self.remove = remove
    self.editLead = editLead
  }
}
