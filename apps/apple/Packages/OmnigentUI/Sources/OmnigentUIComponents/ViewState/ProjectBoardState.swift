public import Foundation

// Mirrors of the core's project board (`omnigent-core` `project_board.rs`): the lanes, the cards
// in them and what dropping a card does are the core's; this is what the page draws.

/// One of the project board's lanes, left to right.
nonisolated public enum ProjectBoardLane: String, Hashable, Sendable, CaseIterable, Identifiable {
  /// Idle with an unsent draft.
  case draft
  /// A decision is pending, the last turn failed, or the agent waits in its terminal.
  case needsAttention
  /// A turn or background work is in progress.
  case working
  /// Finished with activity the user has not seen.
  case unread
  /// Finished and seen.
  case done

  /// The lane itself.
  public var id: Self { self }

  /// The web's lane title.
  public var title: String {
    switch self {
    case .draft: "Draft"
    case .needsAttention: "Needs attention"
    case .working: "Working"
    case .unread: "Unread"
    case .done: "Done"
    }
  }

  /// The lane's SF Symbol.
  public var systemImage: String {
    switch self {
    case .draft: "pencil"
    case .needsAttention: "exclamationmark.bubble"
    case .working: "circle.dotted.circle"
    case .unread: "envelope.badge"
    case .done: "checkmark.circle"
    }
  }
}

/// One card: a session family, or a session on its own.
nonisolated public struct ProjectBoardCard: Hashable, Sendable, Identifiable {
  /// The family's head, or the lone session: what the card shows and opens.
  public var session: SessionSummary
  /// Its row facts: harness, environment, repository, branch, draft.
  public var info: SessionRowInfo
  /// Every session it stands for, head first.
  public var memberIDs: [String]
  /// Its lane.
  public var lane: ProjectBoardLane
  /// A member has activity the user has not seen.
  public var isUnread: Bool
  /// Pending decisions the user can answer, for the Needs you capsule.
  public var requests: Int
  /// The opening sentences of the last reply; `nil` until read, or when there is none.
  public var preview: String?

  /// The head's id.
  public var id: String { session.id }

  /// Sessions nested under the head.
  public var nestedCount: Int { max(0, memberIDs.count - 1) }

  /// Creates a card.
  /// - Parameters:
  ///   - session: The head.
  ///   - info: Its row facts.
  ///   - memberIDs: Every member, head first; empty for the head alone.
  ///   - lane: Its lane.
  ///   - isUnread: A member is unread.
  ///   - requests: Pending decisions.
  ///   - preview: The last reply's opening sentences.
  public init(
    session: SessionSummary, info: SessionRowInfo = SessionRowInfo(), memberIDs: [String] = [],
    lane: ProjectBoardLane, isUnread: Bool = false, requests: Int = 0, preview: String? = nil
  ) {
    self.session = session
    self.info = info
    self.memberIDs = memberIDs.isEmpty ? [session.id] : memberIDs
    self.lane = lane
    self.isUnread = isUnread
    self.requests = requests
    self.preview = preview
  }
}

/// One lane and the cards in it that match the filter.
nonisolated public struct ProjectBoardColumn: Hashable, Sendable, Identifiable {
  /// The lane.
  public var lane: ProjectBoardLane
  /// Its cards, in the board's order.
  public var cards: [ProjectBoardCard]

  /// The lane.
  public var id: ProjectBoardLane { lane }

  /// Creates a lane.
  /// - Parameters:
  ///   - lane: The lane.
  ///   - cards: Its cards.
  public init(lane: ProjectBoardLane, cards: [ProjectBoardCard] = []) {
    self.lane = lane
    self.cards = cards
  }
}

/// Where the board's sessions stand.
nonisolated public enum ProjectBoardPhase: Hashable, Sendable {
  /// The project's first page is loading.
  case loading
  /// It could not be read.
  case failed(message: String)
  /// Read; the lanes may still be empty.
  case loaded
}

/// A project's board (the web's project home): its sessions as cards in five status lanes, the
/// filter, New session's floating composer and a card's quick view beside the lanes.
nonisolated public struct ProjectBoardViewState: Hashable, Sendable {
  /// The project.
  public var project: SessionProject
  /// The lanes left to right, each with its cards.
  public var columns: [ProjectBoardColumn]
  /// Where its sessions stand.
  public var phase: ProjectBoardPhase
  /// More of its sessions are on the server.
  public var hasMore = false
  /// The next page is loading.
  public var isLoadingMore = false
  /// The filter's text.
  public var filter = ""
  /// The row details each card's line shows (the sidebar's Show choice).
  public var details: Set<SessionRowDetail> = [.updated]
  /// How the harness mark leads each card.
  public var harnessIcon = HarnessIconStyle.default
  /// Cards that just joined the board, outlined for a moment.
  public var arrivals: Set<String> = []
  /// The session open in quick view beside the lanes.
  public var quickViewID: String?
  /// New session's composer floats over the lanes.
  public var isComposerShown = false
  /// The projects a card can move to.
  public var projects: [SessionProject] = []
  /// The time ages are counted from; `nil` follows the clock.
  public var now: Date?

  /// Creates the state.
  /// - Parameters:
  ///   - project: The project.
  ///   - columns: The lanes; empty ones for each lane by default.
  ///   - phase: Where its sessions stand.
  public init(
    project: SessionProject,
    columns: [ProjectBoardColumn] = ProjectBoardLane.allCases.map { ProjectBoardColumn(lane: $0) },
    phase: ProjectBoardPhase = .loaded
  ) {
    self.project = project
    self.columns = columns
    self.phase = phase
  }

  /// What an empty lane says.
  public var emptyLabel: String {
    filter.trimmingCharacters(in: .whitespaces).isEmpty ? "No sessions" : "No matching sessions"
  }

  /// The card with this id, in any lane.
  /// - Parameter id: The head's id.
  /// - Returns: The card.
  public func card(_ id: String) -> ProjectBoardCard? {
    columns.lazy.flatMap(\.cards).first { $0.id == id }
  }

  /// The lane a phone opens on: the first with cards, else the first.
  public var openingLane: ProjectBoardLane {
    columns.first { !$0.cards.isEmpty }?.lane ?? .draft
  }
}

/// What the board can do. `nil` hides or disables the matching control.
public struct ProjectBoardActions {
  /// Opens a card's session in full.
  public var open: @MainActor (String) -> Void
  /// Shows a session in quick view beside the lanes, or closes it (`nil`); `nil` offers none.
  public var quickView: (@MainActor (String?) -> Void)?
  /// The filter's text changed.
  public var setFilter: (@MainActor (String) -> Void)?
  /// Whether a card in the first lane can drop on the second (the core's rule).
  public var accepts: @MainActor (ProjectBoardLane, ProjectBoardLane) -> Bool = { _, _ in false }
  /// A card dropped on a lane that accepts it.
  public var drop: (@MainActor (ProjectBoardCard, ProjectBoardLane) -> Void)?
  /// Marks a card read (`false`) or unread (`true`), as its menu does.
  public var setUnread: (@MainActor (ProjectBoardCard, Bool) -> Void)?
  /// Reads a card's reply preview, for its head as it is now.
  public var loadPreview: (@MainActor (ProjectBoardCard) async -> Void)?
  /// Reads the next page of the project's sessions.
  public var loadMore: (@MainActor () -> Void)?
  /// Reads the project's sessions again after a failure.
  public var retry: (@MainActor () -> Void)?
  /// Shows or hides New session's composer.
  public var toggleComposer: (@MainActor () -> Void)?
  /// The session row's actions, for each card's menu.
  public var sessions = SessionListActions()

  /// Creates actions.
  /// - Parameter open: Opens a card's session.
  public init(open: @escaping @MainActor (String) -> Void) {
    self.open = open
  }
}
