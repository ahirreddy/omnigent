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
  /// A page of older history is loading.
  public var isLoadingHistory: Bool
  /// The first read of the conversation is in flight: no row is known yet to be all there is.
  public var isHydrating = false
  /// A session-level error to show (load, stream or send failure). Never swallowed.
  public var errorMessage: String?
  /// Live stream status, for example `Connected` or `Reconnecting in 4 s`.
  public var connectionStatus: String?
  /// The terminal mode's state; `.none` hides the Chat/Terminal switch.
  public var terminal: TerminalStatus
  /// When rows were written, by row id, overriding each row's own ``Row/createdAt``.
  public var timestamps: [String: Date]
  /// How long each assistant turn worked, by response id ("Worked for 2m").
  public var turnDurations: [String: TimeInterval]
  /// When the running turn started, when it is known; the live turn shows "Working · 12s".
  public var turnStartedAt: Date?
  /// The session as the sidebar lists it, for the title menu (pin, archive, unread).
  public var summary: SessionSummary?
  /// The project the session belongs to, shown under the title.
  public var projectName: String?
  /// Shared with other people: user messages show author avatars.
  public var isShared: Bool
  /// The signed-in user's name, so their own messages show no avatar.
  public var viewerName: String?
  /// Pull requests created or linked in this session.
  public var pullRequests: [PullRequestSummary]
  /// The agent's tools and policies, for the Info popover; `nil` hides it.
  public var agentInfo: AgentInfo?
  /// Why sharing is unavailable ("Sharing is unavailable from a local server."), or `nil`.
  public var shareUnavailableReason: String?
  /// The status line's transcript facts when ``rows`` are read live instead; `nil` derives them
  /// from ``rows``.
  public var transcriptStatus: TranscriptStatus?

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
  ///   - terminal: Terminal mode state.
  ///   - timestamps: Row timestamps.
  ///   - turnDurations: Turn durations by response id.
  ///   - summary: The list summary.
  ///   - projectName: Project name.
  ///   - isShared: Shared with others.
  ///   - viewerName: The signed-in user.
  ///   - pullRequests: Pull requests.
  ///   - agentInfo: Agent tools and policies.
  ///   - shareUnavailableReason: Why Share is disabled.
  ///   - turnStartedAt: When the running turn started.
  public init(
    revision: UInt64 = 0, header: SessionHeader, rows: [Row] = [],
    decisions: [DecisionCard] = [], decisionPhases: [String: DecisionPhase] = [:],
    sections: [EventSection] = [], hasMoreHistory: Bool = false, isLoadingHistory: Bool = false,
    errorMessage: String? = nil, connectionStatus: String? = nil, terminal: TerminalStatus = .none,
    timestamps: [String: Date] = [:], turnDurations: [String: TimeInterval] = [:],
    summary: SessionSummary? = nil, projectName: String? = nil, isShared: Bool = false,
    viewerName: String? = nil, pullRequests: [PullRequestSummary] = [],
    agentInfo: AgentInfo? = nil, shareUnavailableReason: String? = nil,
    turnStartedAt: Date? = nil
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
    self.terminal = terminal
    self.timestamps = timestamps
    self.turnDurations = turnDurations
    self.summary = summary
    self.projectName = projectName
    self.isShared = isShared
    self.viewerName = viewerName
    self.pullRequests = pullRequests
    self.agentInfo = agentInfo
    self.shareUnavailableReason = shareUnavailableReason
    self.turnStartedAt = turnStartedAt
  }

  /// The session has a terminal mode (any state but `.none`).
  public var terminalAvailable: Bool { terminal != .none }

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

/// The Terminal mode's state, with the web's offline and resume states.
nonisolated public enum TerminalStatus: Hashable, Sendable {
  /// The session has no terminal mode.
  case none
  /// The sandbox or terminal is starting; `stage` is, for example, "Provisioning sandbox".
  case startingUp(stage: String?)
  /// The terminal is live.
  case ready
  /// "The sandbox is offline." with Resume sandbox.
  case sandboxOffline
  /// "The harness is not running." with Resume session.
  case harnessNotRunning
  /// A resume is in flight.
  case resuming
}

/// One pull request in the right panel.
nonisolated public struct PullRequestSummary: Hashable, Sendable, Identifiable {
  /// The web's status words.
  public enum Status: String, Hashable, Sendable, CaseIterable {
    /// Merge conflicts.
    case conflicts
    /// Checks failing.
    case failing
    /// Ready to merge.
    case ready
    /// Checks running.
    case running
    /// Open.
    case open
    /// Draft.
    case draft
    /// Merged.
    case merged
    /// Closed.
    case closed
    /// The host has not fetched the state yet.
    case unknown

    /// Sort order, as the web ranks statuses: what needs the user first.
    public var priority: Int {
      switch self {
      case .conflicts: 0
      case .failing: 1
      case .ready: 2
      case .running: 3
      case .open: 4
      case .draft: 5
      case .unknown: 6
      case .merged: 7
      case .closed: 8
      }
    }

    /// The label.
    public var title: String {
      switch self {
      case .conflicts: "Merge conflicts"
      case .failing: "Checks failing"
      case .ready: "Ready to merge"
      case .running: "Checks running"
      case .open: "Open"
      case .draft: "Draft"
      case .merged: "Merged"
      case .closed: "Closed"
      case .unknown: "Not checked yet"
      }
    }
  }

  /// Stable id.
  public var id: String
  /// The PR number.
  public var number: Int
  /// Title.
  public var title: String
  /// Repository, `owner/name`.
  public var repo: String
  /// The PR page.
  public var url: String
  /// Status.
  public var status: Status
  /// A second line, for example how the PR joined the session.
  public var detail: String?

  /// Creates a pull request summary.
  /// - Parameters:
  ///   - id: Id.
  ///   - number: Number.
  ///   - title: Title.
  ///   - repo: Repository.
  ///   - url: URL.
  ///   - status: Status.
  ///   - detail: A second line.
  public init(
    id: String, number: Int, title: String, repo: String, url: String, status: Status,
    detail: String? = nil
  ) {
    self.id = id
    self.number = number
    self.title = title
    self.repo = repo
    self.url = url
    self.status = status
    self.detail = detail
  }
}

/// The agent's tools and policies, shown by the header's Info popover.
nonisolated public struct AgentInfo: Hashable, Sendable {
  /// The agent's name.
  public var name: String
  /// Tool names.
  public var tools: [String]
  /// Policy names.
  public var policies: [String]

  /// Creates agent info.
  /// - Parameters:
  ///   - name: Name.
  ///   - tools: Tools.
  ///   - policies: Policies.
  public init(name: String, tools: [String] = [], policies: [String] = []) {
    self.name = name
    self.tools = tools
    self.policies = policies
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
  /// Validates form answers with the core (`validate_form`); returns the first problem and the
  /// field it is about.
  public var validateForm:
    (@MainActor (DecisionCard, [String: ElicitationValue]) -> DecisionFormProblem?)?
  /// Clear ``ConversationViewState/errorMessage``.
  public var dismissError: (@MainActor () -> Void)?
  /// Retry loading after a failure.
  public var retry: (@MainActor () -> Void)?
  /// Fork the conversation after a settled assistant message ("Fork from here").
  public var forkFrom: (@MainActor (Row) -> Void)?
  /// Why the session can't be forked; "Fork from here" then shows disabled with the reason.
  public var forkUnavailableReason: String?
  /// A message's deep link (`?message=<id>`), for Copy Link.
  public var messageURL: (@MainActor (Row) -> URL?)?
  /// Resume the sandbox or the harness (terminal and offline states).
  public var resume: (@MainActor () -> Void)?
  /// Open the Share sheet.
  public var share: (@MainActor () -> Void)?
  /// Open a side question (a `sidechat` row) in its own tab; `nil` hides Open in Tab.
  public var openSideChat: (@MainActor (Row) -> Void)?
  /// Retry a failed turn from its error row, as ``Activity/recovery`` says; `nil` hides Retry.
  public var retryFailedTurn: (@MainActor (Row) -> Void)?
  /// Open a sub-agent's transcript; `nil` falls back to ``openSession``. The one route for
  /// children, so a host can send them somewhere else (a tab) without touching the views.
  public var openChild: (@MainActor (String) -> Void)?
  /// Quote text selected in the transcript in the composer ("Reply"); `nil` hides the
  /// selection popup.
  public var replyWithSelection: (@MainActor (String) -> Void)?
  /// Ask about text selected in the transcript in a new side chat; `nil` hides that choice.
  public var askInSideChat: (@MainActor (String) -> Void)?

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
  ///   - forkFrom: Fork from a message.
  ///   - messageURL: A message's link.
  ///   - resume: Resume the sandbox or harness.
  ///   - share: Open Share.
  public init(
    loadOlder: (@MainActor () -> Void)? = nil, openSession: (@MainActor (String) -> Void)? = nil,
    openAttachment: (@MainActor (Attachment) -> Void)? = nil,
    openURL: (@MainActor (URL) -> Void)? = nil,
    respond: (@MainActor (DecisionCard, DecisionResponse) -> Void)? = nil,
    validateForm:
      (@MainActor (DecisionCard, [String: ElicitationValue]) -> DecisionFormProblem?)? = nil,
    dismissError: (@MainActor () -> Void)? = nil, retry: (@MainActor () -> Void)? = nil,
    forkFrom: (@MainActor (Row) -> Void)? = nil, messageURL: (@MainActor (Row) -> URL?)? = nil,
    resume: (@MainActor () -> Void)? = nil, share: (@MainActor () -> Void)? = nil
  ) {
    self.loadOlder = loadOlder
    self.openSession = openSession
    self.openAttachment = openAttachment
    self.openURL = openURL
    self.respond = respond
    self.validateForm = validateForm
    self.dismissError = dismissError
    self.retry = retry
    self.forkFrom = forkFrom
    self.messageURL = messageURL
    self.resume = resume
    self.share = share
  }
}
