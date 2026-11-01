public import Foundation

/// Where a sub-agent stands: the core's `ChildState`, from the `state` detail of its
/// `child-<id>` section.
nonisolated public enum SubagentStatus: String, Hashable, Sendable, CaseIterable {
  /// Blocked on an approval or a question.
  case needsYou = "needs_you"
  /// Working.
  case running
  /// Starting, with no task reported yet.
  case starting
  /// The latest task failed.
  case failed
  /// Finished and ready for review.
  case ready

  /// The word on the child's row.
  public var title: String {
    switch self {
    case .needsYou: "Needs you"
    case .running: "Running"
    case .starting: "Starting"
    case .failed: "Failed"
    case .ready: "Ready"
    }
  }

  /// "1 running", "2 need you".
  func count(_ count: Int) -> String {
    switch self {
    case .needsYou: "\(count) \(count == 1 ? "needs" : "need") you"
    case .running: "\(count) running"
    case .starting: "\(count) starting"
    case .failed: "\(count) failed"
    case .ready: "\(count) ready"
    }
  }
}

/// One sub-agent in the parent's group row.
nonisolated public struct SubagentChild: Hashable, Sendable, Identifiable {
  /// The child session's id.
  public var id: String
  /// The `child-<id>` section it came from.
  public var sectionID: String
  /// Its title.
  public var title: String
  /// The agent or tool ("researcher", "Codex").
  public var agent: String?
  /// What it was asked to do.
  public var goal: String?
  /// Its latest message.
  public var activity: String?
  /// Why its latest task failed.
  public var error: String?
  /// Where it stands.
  public var status: SubagentStatus
  /// When it started.
  public var startedAt: Date?
  /// Requests mirrored into the parent that target this child, answerable from the parent.
  public var decisions: [DecisionCard]

  /// Creates a child.
  /// - Parameters:
  ///   - id: Child session id.
  ///   - sectionID: Section id.
  ///   - title: Title.
  ///   - agent: Agent or tool.
  ///   - goal: Goal.
  ///   - activity: Latest message.
  ///   - error: Failure.
  ///   - status: Status.
  ///   - startedAt: Start.
  ///   - decisions: Mirrored requests.
  public init(
    id: String, sectionID: String? = nil, title: String, agent: String? = nil,
    goal: String? = nil, activity: String? = nil, error: String? = nil,
    status: SubagentStatus, startedAt: Date? = nil, decisions: [DecisionCard] = []
  ) {
    self.id = id
    self.sectionID = sectionID ?? "child-\(id)"
    self.title = title
    self.agent = agent
    self.goal = goal
    self.activity = activity
    self.error = error
    self.status = status
    self.startedAt = startedAt
    self.decisions = decisions
  }
}

/// The parent's live sub-agent group: `2 agents · 1 running · 1 ready`, expandable to each
/// child's goal, latest activity and pending requests.
nonisolated public struct SubagentGroup: Hashable, Sendable {
  /// Children in the order the core lists them (by start).
  public var children: [SubagentChild]

  /// Creates a group.
  /// - Parameter children: Children.
  public init(children: [SubagentChild]) {
    self.children = children
  }

  /// The group of `state`'s `child-<id>` sections, with the mirrored requests that target each
  /// child; `nil` when the session has no children. A child with an unanswered mirrored request
  /// needs the user whatever its section says, so a pending request is never hidden.
  /// - Parameter state: The parent conversation.
  public init?(state: ConversationViewState) {
    let children: [SubagentChild] = state.sections.compactMap { section in
      guard section.id.hasPrefix("child-"), let id = section.sessionId else { return nil }
      let detail = { (key: String) -> String? in
        section.details.first { $0.id == key }.map(\.text).flatMap { $0.isEmpty ? nil : $0 }
      }
      let decisions = state.decisions.filter { $0.isMirrored && $0.targetSessionId == id }
      let waiting = decisions.contains { card in
        switch state.phase(of: card) {
        case .pending, .resolving, .failed: true
        case .answered: false
        }
      }
      var status = detail("state").flatMap(SubagentStatus.init(rawValue:)) ?? .starting
      if waiting { status = .needsYou }
      return SubagentChild(
        id: id, sectionID: section.id, title: section.title, agent: detail("agent"),
        goal: detail("goal"), activity: detail("activity"), error: detail("error"),
        status: status,
        startedAt: detail("started").flatMap(TimeInterval.init).map(
          Date.init(timeIntervalSince1970:)),
        decisions: decisions)
    }
    guard !children.isEmpty else { return nil }
    self.init(children: children)
  }

  /// How many children are in `status`.
  /// - Parameter status: A status.
  /// - Returns: The count.
  public func count(_ status: SubagentStatus) -> Int {
    children.count { $0.status == status }
  }

  /// The non-zero counts, most urgent first.
  public var counts: [(status: SubagentStatus, count: Int)] {
    SubagentStatus.allCases.compactMap { status in
      let count = count(status)
      return count > 0 ? (status, count) : nil
    }
  }

  /// "2 agents".
  public var total: String {
    "\(children.count) \(children.count == 1 ? "agent" : "agents")"
  }

  /// "2 agents · 1 running · 1 ready".
  public var headline: String {
    ([total] + counts.map { $0.status.count($0.count) }).joined(separator: " \u{00B7} ")
  }

  /// Opens expanded while a child needs the user, so its request is answerable at a glance.
  public var startsExpanded: Bool { count(.needsYou) > 0 }

  /// Children still in play (everything but Ready), in order.
  public var active: [SubagentChild] { children.filter { $0.status != .ready } }

  /// Finished children; they fold to "2 done" while others are still active.
  public var done: [SubagentChild] { children.filter { $0.status == .ready } }

  /// The mirrored requests the group renders, which the transcript's inline list then skips.
  public var decisionIDs: Set<String> {
    Set(children.flatMap { $0.decisions.map(\.id) })
  }

  /// "Subagent · Write auth tests" for a mirrored card, when its child is known.
  /// - Parameters:
  ///   - card: A card.
  ///   - state: The parent conversation.
  /// - Returns: The context, or `nil` when the card is not mirrored.
  public static func context(for card: DecisionCard, in state: ConversationViewState) -> String? {
    guard card.isMirrored else { return nil }
    let title = state.sections.first {
      $0.id.hasPrefix("child-") && $0.sessionId == card.targetSessionId
    }?.title
    return ["Subagent", title].compactMap(\.self).joined(separator: " \u{00B7} ")
  }
}
