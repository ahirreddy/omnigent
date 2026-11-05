public import CoreGraphics

/// Where an agent in the spawn tree stands (the core's `AgentActivity`).
nonisolated public enum AgentTreeActivity: Hashable, Sendable, CaseIterable {
  /// Starting up.
  case launching
  /// Working on a task.
  case working
  /// Blocked on an approval or a question.
  case needsYou
  /// The latest task completed.
  case done
  /// The latest task failed.
  case failed
  /// The runner went away; the task did not fail.
  case disconnected
  /// No task has run.
  case idle
  /// Another task status.
  case other
}

/// What a sub-agent does, for its icon (the core's `AgentRole`).
nonisolated public enum AgentTreeRole: Hashable, Sendable, CaseIterable {
  /// Explores a codebase.
  case explore
  /// Researches.
  case research
  /// Plans or designs.
  case plan
  /// Reviews.
  case review
  /// Tests.
  case test
  /// Writes documents.
  case docs
  /// Writes code.
  case code
  /// Anything else.
  case generic

  /// The SF Symbol.
  public var systemImage: String {
    switch self {
    case .explore: "magnifyingglass"
    case .research: "book"
    case .plan: "safari"
    case .review: "doc.text.magnifyingglass"
    case .test: "flask"
    case .docs: "doc.text"
    case .code: "chevron.left.forwardslash.chevron.right"
    case .generic: "cpu"
    }
  }
}

/// One agent of the spawn tree.
nonisolated public struct AgentTreeNode: Hashable, Sendable, Identifiable {
  /// Its session.
  public var id: String
  /// The agent it runs under; `nil` for the root.
  public var parentID: String?
  /// Levels below the root.
  public var depth: Int
  /// Its name.
  public var name: String
  /// What it does.
  public var role: AgentTreeRole
  /// Where it stands.
  public var activity: AgentTreeActivity
  /// "Working", "Needs you"...
  public var statusLabel: String
  /// The first error line behind a failure.
  public var statusDetail: String?
  /// Finished or idle, so shown dimmed.
  public var isSettled: Bool
  /// Its latest message, one line.
  public var preview: String?
  /// The model smart routing picked for it.
  public var routedModel: String?
  /// Sub-agents listed under it.
  public var childCount: Int

  /// Creates a node.
  public init(
    id: String, parentID: String? = nil, depth: Int = 0, name: String,
    role: AgentTreeRole = .generic, activity: AgentTreeActivity = .idle,
    statusLabel: String = "Idle", statusDetail: String? = nil, isSettled: Bool = false,
    preview: String? = nil, routedModel: String? = nil, childCount: Int = 0
  ) {
    self.id = id
    self.parentID = parentID
    self.depth = depth
    self.name = name
    self.role = role
    self.activity = activity
    self.statusLabel = statusLabel
    self.statusDetail = statusDetail
    self.isSettled = isSettled
    self.preview = preview
    self.routedModel = routedModel
    self.childCount = childCount
  }

  /// "Working: tunnel closed".
  public var statusHelp: String {
    statusDetail.map { "\(statusLabel): \($0)" } ?? statusLabel
  }
}

/// The Agents tab's spawn tree, from the session's top-level ancestor (web `SubagentsPanel`).
nonisolated public struct AgentTreeState: Hashable, Sendable {
  /// The agents, root first, each followed by its own sub-agents.
  public var nodes: [AgentTreeNode]
  /// The session this chat shows, highlighted in the tree.
  public var currentID: String
  /// The first read is in flight.
  public var isLoading: Bool
  /// Why the latest read failed.
  public var errorMessage: String?

  /// Creates the state.
  public init(
    nodes: [AgentTreeNode], currentID: String, isLoading: Bool = false,
    errorMessage: String? = nil
  ) {
    self.nodes = nodes
    self.currentID = currentID
    self.isLoading = isLoading
    self.errorMessage = errorMessage
  }

  /// The nodes shown with `collapsed` folded: a folded agent hides everything under it.
  /// - Parameter collapsed: Folded agents.
  /// - Returns: The visible nodes, in order.
  public func visible(collapsed: Set<String>) -> [AgentTreeNode] {
    var hidden = Set<String>()
    return nodes.filter { node in
      guard let parent = node.parentID else { return true }
      if hidden.contains(parent) || collapsed.contains(parent) {
        hidden.insert(node.id)
        return false
      }
      return true
    }
  }
}

/// The Agents tab's actions.
public struct AgentTreeActions {
  /// Opens an agent's chat.
  public var open: (@MainActor (String) -> Void)?
  /// Reads the tree again.
  public var refresh: (@MainActor () -> Void)?

  /// Creates actions.
  public init(
    open: (@MainActor (String) -> Void)? = nil, refresh: (@MainActor () -> Void)? = nil
  ) {
    self.open = open
    self.refresh = refresh
  }
}

/// The graph view's top-down layout (web `subagentGraphLayout`): each agent centered over its
/// sub-agents, siblings side by side.
nonisolated public enum AgentTreeLayout {
  /// A node's size.
  public static let nodeSize = CGSize(width: 180, height: 64)
  /// Space between siblings.
  public static let horizontalGap: CGFloat = 32
  /// Space between levels.
  public static let verticalGap: CGFloat = 36

  /// Node centers, and the size the tree takes, with its top-left corner at the origin.
  /// - Parameter nodes: The tree, root first, each node followed by its sub-agents.
  /// - Returns: The centers by session id, and the bounding size.
  public static func layout(_ nodes: [AgentTreeNode]) -> (centers: [String: CGPoint], size: CGSize)
  {
    guard let root = nodes.first else { return ([:], .zero) }
    var children: [String: [String]] = [:]
    for node in nodes.dropFirst() {
      if let parent = node.parentID { children[parent, default: []].append(node.id) }
    }
    var widths: [String: CGFloat] = [:]
    func width(_ id: String) -> CGFloat {
      let kids = children[id] ?? []
      let total =
        kids.reduce(0) { $0 + width($1) } + CGFloat(max(kids.count - 1, 0)) * horizontalGap
      let result = max(nodeSize.width, total)
      widths[id] = result
      return result
    }
    let totalWidth = width(root.id)
    var centers: [String: CGPoint] = [:]
    var bottom: CGFloat = 0
    func place(_ id: String, center centerX: CGFloat, top: CGFloat) {
      centers[id] = CGPoint(x: centerX, y: top + nodeSize.height / 2)
      bottom = max(bottom, top + nodeSize.height)
      let kids = children[id] ?? []
      let span =
        kids.reduce(0) { $0 + (widths[$1] ?? 0) } + CGFloat(max(kids.count - 1, 0)) * horizontalGap
      var left = centerX - span / 2
      for kid in kids {
        let kidWidth = widths[kid] ?? nodeSize.width
        place(kid, center: left + kidWidth / 2, top: top + nodeSize.height + verticalGap)
        left += kidWidth + horizontalGap
      }
    }
    place(root.id, center: totalWidth / 2, top: 0)
    return (centers, CGSize(width: totalWidth, height: bottom))
  }
}
