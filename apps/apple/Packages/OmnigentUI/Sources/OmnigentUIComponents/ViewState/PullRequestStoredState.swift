public import Foundation

/// The open PR as the server last stored it, shown while the session's host is offline: its
/// title, link and state, and when the host can load the rest.
nonisolated public struct PullRequestStoredViewState: Hashable, Sendable {
  /// The PR page.
  public var url: String
  /// The stored title, or the repository and number.
  public var title: String
  /// "#7".
  public var numberLabel: String
  /// `owner/repo`.
  public var repository: String
  /// The stored state.
  public var status: PullRequestSummary.Status
  /// The provider's name, for "Open on GitHub".
  public var providerName: String
  /// When the state was read, and what loads the rest.
  public var hint: String

  /// Creates the state.
  /// - Parameters:
  ///   - url: Page.
  ///   - title: Title.
  ///   - numberLabel: "#7".
  ///   - repository: Repository.
  ///   - status: Stored state.
  ///   - providerName: Provider.
  ///   - hint: The status line.
  public init(
    url: String, title: String, numberLabel: String, repository: String,
    status: PullRequestSummary.Status, providerName: String, hint: String
  ) {
    self.url = url
    self.title = title
    self.numberLabel = numberLabel
    self.repository = repository
    self.status = status
    self.providerName = providerName
    self.hint = hint
  }
}

/// A commit or force push in the Comments tab's feed.
nonisolated public struct PullRequestTimelineRow: Hashable, Sendable, Identifiable {
  /// Commit or force push.
  public enum Kind: Hashable, Sendable {
    /// A commit.
    case commit
    /// A force push, from the previous head.
    case forcePush(previousSHA: String?)
  }

  /// Stable id.
  public var id: String
  /// What happened.
  public var kind: Kind
  /// Who did it.
  public var author: String
  /// When.
  public var date: Date?
  /// The commit, abbreviated to seven characters when shown.
  public var sha: String?
  /// The commit message's first line.
  public var message: String?
  /// The commit or push on the provider.
  public var url: URL?

  /// Creates a row.
  /// - Parameters:
  ///   - id: Id.
  ///   - kind: Kind.
  ///   - author: Author.
  ///   - date: When.
  ///   - sha: Commit.
  ///   - message: Message.
  ///   - url: Page.
  public init(
    id: String, kind: Kind, author: String, date: Date?, sha: String?, message: String?,
    url: URL?
  ) {
    self.id = id
    self.kind = kind
    self.author = author
    self.date = date
    self.sha = sha
    self.message = message
    self.url = url
  }
}

/// One entry of the Comments tab's chronological feed.
nonisolated public enum PullRequestFeedEntry: Hashable, Sendable, Identifiable {
  /// A conversation comment.
  case comment(PullRequestCommentRow)
  /// A commit or force push.
  case event(PullRequestTimelineRow)

  /// Stable id.
  public var id: String {
    switch self {
    case .comment(let comment): "comment-\(comment.id)"
    case .event(let event): "event-\(event.id)"
    }
  }

  /// When it happened; `nil` sorts last.
  public var date: Date? {
    switch self {
    case .comment(let comment): comment.date
    case .event(let event): event.date
    }
  }
}
