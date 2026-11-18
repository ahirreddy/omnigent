public import Foundation

/// A comment in an inline review conversation.
nonisolated public struct PullRequestReviewCommentRow: Hashable, Sendable, Identifiable {
  /// Stable id.
  public var id: String
  /// The author.
  public var author: String
  /// When.
  public var date: Date?
  /// Markdown.
  public var body: String
  /// Its page.
  public var url: URL?
  /// The provider hides it.
  public var hidden: Bool

  /// Creates a row.
  /// - Parameters:
  ///   - id: Id.
  ///   - author: Author.
  ///   - date: When.
  ///   - body: Markdown.
  ///   - url: Page.
  ///   - hidden: Hidden on the provider.
  public init(id: String, author: String, date: Date?, body: String, url: URL?, hidden: Bool) {
    self.id = id
    self.author = author
    self.date = date
    self.body = body
    self.url = url
    self.hidden = hidden
  }
}

/// An inline review conversation, as the web's `PullRequestReviewThread` shows it.
nonisolated public struct PullRequestReviewThreadState: Hashable, Sendable, Identifiable {
  /// Stable id.
  public var id: String
  /// "New line 12", "Old lines 2–4" or "File conversation".
  public var lineLabel: String
  /// Its lines changed since it was written.
  public var outdated: Bool
  /// Resolved on the provider; it starts folded.
  public var resolved: Bool
  /// The comments, oldest first.
  public var comments: [PullRequestReviewCommentRow]
  /// Older comments remain to be read.
  public var hasOlderComments: Bool
  /// Why some comments could not be read.
  public var warning: String?
  /// The viewer can reply.
  public var canReply: Bool
  /// The reply being written.
  public var reply: String
  /// The patch lines it was written on, for a conversation no line holds.
  public var originalContext: String?

  /// Creates a conversation.
  /// - Parameters:
  ///   - id: Id.
  ///   - lineLabel: Where it is.
  ///   - comments: Comments.
  public init(id: String, lineLabel: String, comments: [PullRequestReviewCommentRow]) {
    self.id = id
    self.lineLabel = lineLabel
    self.comments = comments
    outdated = false
    resolved = false
    hasOlderComments = false
    canReply = false
    reply = ""
  }
}

/// A new conversation being written on lines of the diff.
nonisolated public struct PullRequestNewThreadState: Hashable, Sendable {
  /// "New line 12" or "Old lines 2–4".
  public var lineLabel: String
  /// The comment.
  public var body: String
  /// Why it can't be posted yet.
  public var problem: String?
  /// Whether it goes to the agent rather than the provider.
  public var toAgent = false
  /// The provider takes new threads.
  public var offersProvider = true
  /// The server keeps local comments for the agent.
  public var offersAgent = false
  /// The PR moved since the lines were chosen.
  public var isStale = false

  /// Creates the state.
  /// - Parameters:
  ///   - lineLabel: Where it goes.
  ///   - body: Comment.
  ///   - problem: Why it can't be posted.
  public init(lineLabel: String, body: String, problem: String?) {
    self.lineLabel = lineLabel
    self.body = body
    self.problem = problem
  }
}

/// What review conversations can do. `nil` hides the control.
public struct PullRequestReviewActions {
  /// Keeps a reply's text, by thread.
  public var setReply: (@MainActor (_ threadID: String, _ text: String) -> Void)?
  /// Posts a thread's reply.
  public var reply: (@MainActor (_ threadID: String) -> Void)?
  /// Reads a thread's older comments.
  public var loadOlder: (@MainActor (_ threadID: String) -> Void)?
  /// Keeps the new conversation's text.
  public var setNewBody: (@MainActor (String) -> Void)?
  /// Posts the new conversation.
  public var postNew: (@MainActor () -> Void)?
  /// Drops the new conversation.
  public var cancelNew: (@MainActor () -> Void)?
  /// Sends the new comment to the agent (`true`) or the provider.
  public var setNewToAgent: (@MainActor (Bool) -> Void)?
  /// A change is in flight.
  public var isBusy = false

  /// No actions.
  public init() {}
}

extension PullRequestReviewThreadState {
  /// Where a conversation sits: "New line 12", "Old lines 2–4", or "File conversation" without
  /// a line (the web's label).
  /// - Parameters:
  ///   - old: On the old side.
  ///   - start: Its first line, for a range.
  ///   - end: Its last line.
  /// - Returns: The label.
  public static func lineLabel(old: Bool, start: UInt64?, end: UInt64?) -> String {
    guard let end else { return "File conversation" }
    let side = old ? "Old" : "New"
    if let start, start < end { return "\(side) lines \(start)\u{2013}\(end)" }
    return "\(side) line \(end)"
  }
}
