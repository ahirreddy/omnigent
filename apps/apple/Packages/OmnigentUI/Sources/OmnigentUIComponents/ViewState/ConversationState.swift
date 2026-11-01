public import Foundation

/// Everything the conversation surface renders for one session: the core's
/// `ConversationSnapshot` plus the sections and decision cards the store publishes.
nonisolated public struct ConversationViewState: Hashable, Sendable {
  /// Increases with every published change.
  public var revision: UInt64
  /// Session metadata.
  public var header: SessionHeader
  /// Rows in chronological order, ids unique. Rows with `isActivityOnly` go to the inspector.
  public var rows: [Row]
  /// Decision cards, pending or locally answered.
  public var decisions: [DecisionCard]
  /// Where each card stands, by card id. A missing entry means ``DecisionPhase/pending`` (or
  /// answered when the card says so).
  public var decisionPhases: [String: DecisionPhase]
  /// Session sections (usage, plan, viewers, children, changed files, ...).
  public var sections: [EventSection]
  /// Older history can be loaded.
  public var hasMoreHistory: Bool
  /// Older history is loading.
  public var isLoadingHistory: Bool
  /// A session-level error to show (load, stream or send failure). Never swallowed.
  public var errorMessage: String?
  /// Live stream status, for example `Connected` or `Reconnecting in 4 s`.
  public var connectionStatus: String?
  /// The session's harness runs as a terminal UI the app can show (native Claude Code, Codex, Pi).
  public var terminalAvailable: Bool
  /// The terminal is being created; the Terminal mode shows progress until it is available.
  public var terminalStartingUp: Bool

  /// Creates conversation state.
  /// - Parameters:
  ///   - revision: Change counter.
  ///   - header: Session metadata.
  ///   - rows: Rows.
  ///   - decisions: Decision cards.
  ///   - decisionPhases: Card phases by id.
  ///   - sections: Session sections.
  ///   - hasMoreHistory: Older history exists.
  ///   - isLoadingHistory: Older history is loading.
  ///   - errorMessage: Session error.
  ///   - connectionStatus: Stream status.
  ///   - terminalAvailable: A terminal mode is available.
  ///   - terminalStartingUp: The terminal is starting.
  public init(
    revision: UInt64 = 0, header: SessionHeader, rows: [Row] = [],
    decisions: [DecisionCard] = [], decisionPhases: [String: DecisionPhase] = [:],
    sections: [EventSection] = [], hasMoreHistory: Bool = false, isLoadingHistory: Bool = false,
    errorMessage: String? = nil, connectionStatus: String? = nil, terminalAvailable: Bool = false,
    terminalStartingUp: Bool = false
  ) {
    self.revision = revision
    self.header = header
    self.rows = rows
    self.decisions = decisions
    self.decisionPhases = decisionPhases
    self.sections = sections
    self.hasMoreHistory = hasMoreHistory
    self.isLoadingHistory = isLoadingHistory
    self.errorMessage = errorMessage
    self.connectionStatus = connectionStatus
    self.terminalAvailable = terminalAvailable
    self.terminalStartingUp = terminalStartingUp
  }

  /// The phase of `card`.
  /// - Parameter card: A card from ``decisions``.
  /// - Returns: Its phase.
  public func phase(of card: DecisionCard) -> DecisionPhase {
    if let phase = decisionPhases[card.id] { return phase }
    return card.answered ? .answered(summary: "Response sent") : .pending
  }

  /// Cards the user has not answered, in order.
  public var pendingDecisions: [DecisionCard] {
    decisions.filter { !$0.answered }
  }

  /// Rows that belong in the transcript.
  public var transcriptRows: [Row] { rows.filter { !$0.isActivityOnly } }

  /// Routine lifecycle rows that belong in the activity drawer.
  public var lifecycleRows: [Row] { rows.filter(\.isActivityOnly) }

  /// The section with `id`.
  /// - Parameter id: The section id.
  /// - Returns: The section, if reported.
  public func section(_ id: String) -> EventSection? {
    sections.first { $0.id == id }
  }
}

/// What the conversation surface can ask the host to do. Every closure runs on the main actor;
/// a host that cannot do something passes `nil`, and the control is hidden or disabled.
public struct ConversationActions {
  /// Load the previous page of history.
  public var loadOlder: (@MainActor () -> Void)?
  /// Open another session (a child, the superseding session, a sidechat origin).
  public var openSession: (@MainActor (String) -> Void)?
  /// Preview an attachment explicitly (QuickLook or the web app). Never called automatically.
  public var openAttachment: (@MainActor (Attachment) -> Void)?
  /// Open an external `http(s)` link the user clicked.
  public var openURL: (@MainActor (URL) -> Void)?
  /// Answer a decision card.
  public var respond: (@MainActor (DecisionCard, DecisionResponse) -> Void)?
  /// Validates form answers with the core (`DecisionForm::validate`); returns a readable problem.
  public var validateForm: (@MainActor (DecisionCard, [String: ElicitationValue]) -> String?)?
  /// Clear ``ConversationViewState/errorMessage``.
  public var dismissError: (@MainActor () -> Void)?
  /// Retry loading after a failure.
  public var retry: (@MainActor () -> Void)?

  /// Creates actions.
  /// - Parameters:
  ///   - loadOlder: Load older history.
  ///   - openSession: Open a session by id.
  ///   - openAttachment: Preview an attachment.
  ///   - openURL: Open a link.
  ///   - respond: Answer a card.
  ///   - validateForm: Validate form answers.
  ///   - dismissError: Clear the error.
  ///   - retry: Retry after a failure.
  public init(
    loadOlder: (@MainActor () -> Void)? = nil, openSession: (@MainActor (String) -> Void)? = nil,
    openAttachment: (@MainActor (Attachment) -> Void)? = nil,
    openURL: (@MainActor (URL) -> Void)? = nil,
    respond: (@MainActor (DecisionCard, DecisionResponse) -> Void)? = nil,
    validateForm: (@MainActor (DecisionCard, [String: ElicitationValue]) -> String?)? = nil,
    dismissError: (@MainActor () -> Void)? = nil, retry: (@MainActor () -> Void)? = nil
  ) {
    self.loadOlder = loadOlder
    self.openSession = openSession
    self.openAttachment = openAttachment
    self.openURL = openURL
    self.respond = respond
    self.validateForm = validateForm
    self.dismissError = dismissError
    self.retry = retry
  }
}
