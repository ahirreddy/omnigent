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
    /// An item an agent posted for its owner: a follow-up, information or a reminder.
    case suggestion
    /// An automation whose latest run failed before it made a session.
    case automationFailure

    /// The label.
    public var title: String {
      switch self {
      case .approval: "Approval needed"
      case .question: "Question"
      case .comment: "Comment"
      case .unread: "Unread"
      case .suggestion: "Suggestion"
      case .automationFailure: "Automation failed"
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
  /// A file comment's details, for ``Kind/comment``.
  public var comment: InboxComment?
  /// An unread session that ended in an error ("Error" rather than "Done").
  public var isError = false
  /// Whether a reply can be sent from the Inbox (editor access to an unread session).
  public var canReply = false
  /// The inline reply's progress.
  public var reply: InboxReplyPhase = .idle
  /// The agent's whole reply when ``preview`` is cut from it.
  public var fullText: String?
  /// An agent-posted item's details, for ``Kind/suggestion``.
  public var suggestion: InboxSuggestion?
  /// A failed automation's details, for ``Kind/automationFailure``.
  public var automationFailure: InboxAutomationFailure?

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

  /// A binary approval that needs no review first: one shortcut or swipe answers it. A plan is
  /// read before it is approved, so it never qualifies.
  public var approvesDirectly: Bool { canApprove && decision?.permissions.plan == nil }

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

/// A comment someone left on a session's file.
nonisolated public struct InboxComment: Hashable, Sendable {
  /// Who left it.
  public var author: String
  /// File path relative to the workspace.
  public var path: String
  /// The commented text.
  public var anchor: String?
  /// The comment.
  public var body: String

  /// Creates a comment.
  public init(author: String, path: String, anchor: String? = nil, body: String) {
    self.author = author
    self.path = path
    self.anchor = anchor
    self.body = body
  }
}

/// Where an inline Inbox reply stands.
nonisolated public enum InboxReplyPhase: Hashable, Sendable {
  /// Nothing sent.
  case idle
  /// In flight.
  case sending
  /// Sent; the agent's answer shows up here.
  case sent
  /// Not sent; the draft stays.
  case failed(message: String)
}

/// The Inbox's filter.
nonisolated public enum InboxFilter: String, Hashable, Sendable, CaseIterable, Identifiable {
  /// All.
  case all
  /// Unread.
  case unread
  /// Awaiting response.
  case awaiting
  /// Omni Advisor's suggestions, while it runs for the caller.
  case advisor

  /// The filter itself.
  public var id: Self { self }

  /// The label.
  public var title: String {
    switch self {
    case .all: "All"
    case .unread: "Unread"
    case .awaiting: "Needs you"
    case .advisor: "Omni Advisor"
    }
  }

  /// The tabs to offer: Omni Advisor's only while it runs for the caller, or, while its settings
  /// load, where it was already chosen, so a viewer who turned it off never sees it flash.
  /// - Parameters:
  ///   - advisorTab: Whether the advisor runs for the caller.
  ///   - chosen: The stored choice.
  /// - Returns: The tabs, in order.
  public static func offered(advisorTab: InboxAdvisorTab, chosen: Self) -> [Self] {
    let showsAdvisor =
      switch advisorTab {
      case .shown: true
      case .hidden: false
      case .loading: chosen == .advisor
      }
    return showsAdvisor ? allCases : allCases.filter { $0 != .advisor }
  }

  /// The tab that applies: the chosen one, or All when it isn't offered.
  public static func effective(_ chosen: Self, advisorTab: InboxAdvisorTab) -> Self {
    offered(advisorTab: advisorTab, chosen: chosen).contains(chosen) ? chosen : .all
  }
}

/// Whether the Inbox offers Omni Advisor's tab.
nonisolated public enum InboxAdvisorTab: Hashable, Sendable {
  /// The server doesn't offer the advisor, or it is off for the caller.
  case hidden
  /// Its settings are being read.
  case loading
  /// It runs for the caller.
  case shown
}

/// The Inbox.
nonisolated public struct InboxViewState: Hashable, Sendable {
  /// Items, newest first.
  public var items: [InboxItem]
  /// The reference "now" for grouping; `nil` uses the current date.
  public var now: Date?

  /// The shared attention model's count; never inferred from loaded rows.
  public var needsYouCount: Int?
  /// Sessions whose Inbox items could not be read; their items are missing.
  public var failedSessionCount = 0
  /// Items are still being read (the session list, requests, comments or replies), so an empty
  /// list does not yet mean nothing is waiting.
  public var isAssembling = false
  /// More sessions exist after the loaded ones; their items are not known yet.
  public var hasMoreSessions = false
  /// A page of them is loading.
  public var isLoadingMoreSessions = false
  /// Agent-posted items could not be read.
  public var suggestionsFailed = false
  /// More agent-posted items are on the server.
  public var hasMoreSuggestions = false
  /// A page of them is loading.
  public var isLoadingMoreSuggestions = false
  /// The server refused a response to an agent-posted item.
  public var suggestionWriteFailed = false
  /// Agent-posted items the caller has not read, as the server counts them.
  public var unreadSuggestionCount = 0
  /// The server stopped counting them at its cap.
  public var unreadSuggestionsCapped = false
  /// Omni Advisor's tab.
  public var advisorTab = InboxAdvisorTab.hidden
  /// Omni Advisor's settings could not be read, so its suggestions can't be told apart.
  public var advisorSettingsFailed = false
  /// Automation failures could not be read.
  public var automationsFailed = false
  /// More automations remain to check.
  public var hasMoreAutomations = false
  /// A page of them is loading.
  public var isLoadingMoreAutomations = false

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
  /// Validates a form request's answers with the core (`validate_form`); returns the first
  /// problem and the field it is about.
  public var validateForm:
    (@MainActor (DecisionCard, [String: ElicitationValue]) -> DecisionFormProblem?)?
  /// The reply draft changed after a failure or a sent reply.
  public var editReply: (@MainActor (InboxItem) -> Void)?
  /// Read the items that failed again.
  public var retry: (@MainActor () -> Void)?
  /// Load the page of sessions after the loaded ones ("Load more sessions").
  public var loadMoreSessions: (@MainActor () -> Void)?
  /// Take an agent-posted item's action at an index: it opens a new session with its prompt.
  public var takeSuggestionAction: (@MainActor (InboxItem, Int) -> Void)?
  /// Dismiss an agent-posted item for a reason.
  public var dismissSuggestion: (@MainActor (InboxItem, InboxDismissChoice) -> Void)?
  /// Open a link on an agent-posted item.
  public var openLink: (@MainActor (InboxLink) -> Void)?
  /// Open the session an agent-posted item came from.
  public var openSource: (@MainActor (InboxItem) -> Void)?
  /// Open a failed automation.
  public var openAutomation: (@MainActor (InboxItem) -> Void)?
  /// Read agent-posted items again.
  public var retrySuggestions: (@MainActor () -> Void)?
  /// Load more agent-posted items.
  public var loadMoreSuggestions: (@MainActor () -> Void)?
  /// Read automation failures again.
  public var retryAutomations: (@MainActor () -> Void)?
  /// Read Omni Advisor's settings again.
  public var retryAdvisorSettings: (@MainActor () -> Void)?
  /// Check more automations for failures.
  public var loadMoreAutomations: (@MainActor () -> Void)?

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
