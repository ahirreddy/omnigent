public import Foundation

/// One board of the Canvas: Main or a project.
nonisolated public struct CanvasBoard: Hashable, Sendable, Identifiable {
  /// The board id.
  public var id: String
  /// "Main" or the project's name.
  public var name: String
  /// The project's emoji icon, when set.
  public var icon: String?

  /// Creates a board.
  public init(id: String, name: String, icon: String? = nil) {
    self.id = id
    self.name = name
    self.icon = icon
  }
}

/// The PR a card links to, as the web's card shows it.
nonisolated public struct CanvasPullRequest: Hashable, Sendable {
  /// "#212 Ship the upload retry".
  public var text: String
  /// Its page.
  public var url: URL
  /// "Ship the upload retry (merged, as of 2h ago)".
  public var tooltip: String
  /// "Open pull request #212".
  public var accessibilityLabel: String

  /// Creates a link.
  /// - Parameters:
  ///   - text: What the card shows.
  ///   - url: The page.
  ///   - tooltip: Its title and state.
  ///   - accessibilityLabel: What VoiceOver says.
  public init(text: String, url: URL, tooltip: String, accessibilityLabel: String) {
    self.text = text
    self.url = url
    self.tooltip = tooltip
    self.accessibilityLabel = accessibilityLabel
  }

  /// The web's card tooltip: the title, then the stored state and, once past fresh, its age
  /// ("Ship it (merged, as of 2h ago)").
  /// - Parameters:
  ///   - title: The PR's title, or its number when it has none.
  ///   - pullRequest: Its stored state and when it was fetched.
  ///   - now: The time to measure the age from.
  /// - Returns: The tooltip.
  public static func tooltip(title: String, _ pullRequest: SessionRowPullRequest, now: Date)
    -> String
  {
    guard let status = pullRequest.status else { return title }
    var state = status.lowercased()
    if let checked = pullRequest.checkedAt,
      now.timeIntervalSince(checked) >= SessionRowTooltip.pullRequestFreshness
    {
      state += ", as of \(RelativeTime.short(checked, now: now)) ago"
    }
    return "\(title) (\(state))"
  }
}

/// One session's card, as the sidebar row shows it.
nonisolated public struct CanvasCard: Hashable, Sendable, Identifiable {
  /// The card's state badge.
  public enum State: Hashable, Sendable {
    /// Waiting on the user.
    case needsYou
    /// A turn is running.
    case running
    /// New messages since the user last looked.
    case unread
    /// The last turn failed.
    case failed
    /// Nothing happening.
    case idle

    /// The label under the title.
    public var label: String {
      switch self {
      case .needsYou: "Needs response"
      case .running: "Running"
      case .unread: "New messages"
      case .failed: "Failed"
      case .idle: "Idle"
      }
    }
  }

  /// The session.
  public var id: String
  /// The session's title.
  public var title: String
  /// Its state.
  public var state: State
  /// The working directory, or "No working directory".
  public var workspace: String
  /// The worktree branch, when it has one.
  public var branch: String?
  /// How many requests wait on the user.
  public var requests = 1
  /// The session's PR, when the server stores one.
  public var pullRequest: CanvasPullRequest?
  /// The card's left edge on the board, in points.
  public var left: Int
  /// The card's top edge on the board, in points.
  public var top: Int

  /// Creates a card.
  public init(
    id: String, title: String, state: State, workspace: String, branch: String? = nil,
    left: Int, top: Int
  ) {
    self.id = id
    self.title = title
    self.state = state
    self.workspace = workspace
    self.branch = branch
    self.left = left
    self.top = top
  }
}

/// The Canvas page.
nonisolated public struct CanvasViewState: Hashable, Sendable {
  /// Main first, then each project.
  public var boards: [CanvasBoard]
  /// The board on screen.
  public var activeBoard: String
  /// The cards on the active board.
  public var cards: [CanvasCard]
  /// The first load has not landed yet.
  public var isLoading = false
  /// A reload is in flight with the cards on screen.
  public var isRefreshing = false
  /// The first load failed; nothing is on screen.
  public var loadError: String?
  /// A reload failed; the earlier cards stay.
  public var refreshError: String?
  /// What the empty board says.
  public var emptyTitle = "No sessions"
  /// The session open beside the board.
  public var quickViewID: String?

  /// Creates the state.
  public init(boards: [CanvasBoard], activeBoard: String, cards: [CanvasCard]) {
    self.boards = boards
    self.activeBoard = activeBoard
    self.cards = cards
  }
}

/// What the Canvas can do.
public struct CanvasActions {
  /// Open a session.
  public var open: (@MainActor (String) -> Void)?
  /// Show a board.
  public var selectBoard: (@MainActor (String) -> Void)?
  /// A card was dropped with its top-left corner at `(left, top)`.
  public var move: (@MainActor (String, Int, Int) -> Void)?
  /// Lay the board's cards out afresh.
  public var resetLayout: (@MainActor () -> Void)?
  /// Start a session (in the board's project).
  public var newSession: (@MainActor () -> Void)?
  /// Load again after a failure.
  public var retry: (@MainActor () -> Void)?
  /// Show a session beside the board, or close it (`nil`); without it a card opens its
  /// session in place of the board.
  public var quickView: (@MainActor (String?) -> Void)?

  /// Creates actions.
  public init(open: (@MainActor (String) -> Void)? = nil) {
    self.open = open
  }
}
