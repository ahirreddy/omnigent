public import Foundation

/// One Inbox item.
nonisolated public struct InboxItem: Hashable, Sendable, Identifiable {
  /// What the item is.
  public enum Kind: Hashable, Sendable {
    /// "Approval needed".
    case approval
    /// "Question".
    case question
    /// "Comment".
    case comment
    /// An unread session.
    case unread

    /// The label.
    public var title: String {
      switch self {
      case .approval: "Approval needed"
      case .question: "Question"
      case .comment: "Comment"
      case .unread: "Unread"
      }
    }
  }

  /// Stable id.
  public var id: String
  /// Kind.
  public var kind: Kind
  /// The session.
  public var sessionId: String
  /// The session title.
  public var sessionTitle: String
  /// One line.
  public var preview: String
  /// When.
  public var date: Date
  /// Not read yet.
  public var isUnread: Bool
  /// The decision to answer in place, for approvals and questions.
  public var decision: DecisionCard?

  /// The agent responsible for this request.
  public var agentName: String = ""
  /// Server, host and workspace context supplied by the adapter.
  public var executionContext: String = ""
  /// Pinned items remain available after reading or resolving them.
  public var isPinned = false
  /// Request creation time, when the server supplies it.
  public var waitingSince: Date?
  /// Resolution progress and errors.
  public var phase: DecisionPhase = .pending
  /// Whether this account can respond.
  public var isReadOnly = false

  /// A pending request is independent of whether it has been read.
  public var isUnresolved: Bool {
    switch phase {
    case .answered: return false
    case .resolving, .failed: return true
    case .pending: break
    }
    if let decision { return !decision.answered }
    return kind == .approval || kind == .question
  }

  /// A binary approval that can be accepted without filling in a form.
  public var canApprove: Bool {
    guard !isReadOnly, isUnresolved, let decision, case .approval = decision.kind else {
      return false
    }
    switch phase {
    case .pending, .failed: return true
    case .resolving, .answered: return false
    }
  }

  /// Creates an item.
  /// - Parameters:
  ///   - id: Id.
  ///   - kind: Kind.
  ///   - sessionId: Session.
  ///   - sessionTitle: Session title.
  ///   - preview: Preview.
  ///   - date: When.
  ///   - isUnread: Unread.
  ///   - decision: Decision card.
  public init(
    id: String, kind: Kind, sessionId: String, sessionTitle: String, preview: String, date: Date,
    isUnread: Bool = true, decision: DecisionCard? = nil
  ) {
    self.id = id
    self.kind = kind
    self.sessionId = sessionId
    self.sessionTitle = sessionTitle
    self.preview = preview
    self.date = date
    self.isUnread = isUnread
    self.decision = decision
  }
}

/// The Inbox's filter.
nonisolated public enum InboxFilter: String, Hashable, Sendable, CaseIterable, Identifiable {
  /// All.
  case all
  /// Unread.
  case unread
  /// Awaiting response.
  case awaiting

  /// The filter itself.
  public var id: Self { self }

  /// The label.
  public var title: String {
    switch self {
    case .all: "All"
    case .unread: "Unread"
    case .awaiting: "Needs you"
    }
  }
}

/// The Inbox.
nonisolated public struct InboxViewState: Hashable, Sendable {
  /// Items, newest first.
  public var items: [InboxItem]
  /// The reference "now" for grouping; `nil` uses the current date.
  public var now: Date?

  /// The shared attention model's count; never inferred from loaded rows.
  public var needsYouCount: Int?

  /// Creates Inbox state.
  /// - Parameters:
  ///   - items: Items.
  ///   - now: Reference date.
  public init(items: [InboxItem], now: Date? = nil) {
    self.items = items
    self.now = now
  }
}

/// Inbox actions.
public struct InboxActions {
  /// Open the item's session.
  public var open: (@MainActor (InboxItem) -> Void)?
  /// Mark as read.
  public var markRead: (@MainActor (InboxItem) -> Void)?
  /// Reply to the session in place.
  public var reply: (@MainActor (InboxItem, String) -> Void)?
  /// Answer the item's decision in place.
  public var respond: (@MainActor (DecisionCard, DecisionResponse) -> Void)?

  /// Creates actions.
  /// - Parameters:
  ///   - open: Open session.
  ///   - markRead: Mark as read.
  ///   - reply: Reply.
  ///   - respond: Answer a decision.
  public init(
    open: (@MainActor (InboxItem) -> Void)? = nil,
    markRead: (@MainActor (InboxItem) -> Void)? = nil,
    reply: (@MainActor (InboxItem, String) -> Void)? = nil,
    respond: (@MainActor (DecisionCard, DecisionResponse) -> Void)? = nil
  ) {
    self.open = open
    self.markRead = markRead
    self.reply = reply
    self.respond = respond
  }
}
