public import Foundation

/// One sub-agent of the parent, from its `child-<id>` section.
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
  public var status: AgentTreeActivity
  /// The word for where it stands ("Working", or a task status as reported).
  public var statusLabel: String
  /// When it started.
  public var startedAt: Date?

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
  ///   - statusLabel: Status word; the status's title when `nil`.
  ///   - startedAt: Start.
  public init(
    id: String, sectionID: String? = nil, title: String, agent: String? = nil,
    goal: String? = nil, activity: String? = nil, error: String? = nil,
    status: AgentTreeActivity, statusLabel: String? = nil, startedAt: Date? = nil
  ) {
    self.id = id
    self.sectionID = sectionID ?? "child-\(id)"
    self.title = title
    self.agent = agent
    self.goal = goal
    self.activity = activity
    self.error = error
    self.status = status
    self.statusLabel = statusLabel ?? status.title
    self.startedAt = startedAt
  }

  /// What its row is called (web `subagentLabel`): its task, else its title.
  public var name: String { goal ?? title }
}

/// The parent's sub-agents, from its `child-<id>` sections, for the composer's count and the
/// Agents tab.
nonisolated public struct SubagentGroup: Hashable, Sendable {
  /// Children in the order the core lists them (by start).
  public var children: [SubagentChild]

  /// Creates a group.
  /// - Parameter children: Children.
  public init(children: [SubagentChild]) {
    self.children = children
  }

  /// The children of `state`'s `child-<id>` sections; `nil` when the session has none. A child
  /// with an unanswered mirrored request needs the user whatever its section says, so a pending
  /// request is never hidden.
  /// - Parameter state: The parent conversation.
  public init?(state: ConversationViewState) {
    let children: [SubagentChild] = state.sections.compactMap { section in
      guard section.id.hasPrefix("child-"), let id = section.sessionId else { return nil }
      let detail = { (key: String) -> String? in
        section.details.first { $0.id == key }.map(\.text).flatMap { $0.isEmpty ? nil : $0 }
      }
      let waiting = state.decisions.contains { card in
        guard card.isMirrored, card.targetSessionId == id else { return false }
        switch state.phase(of: card) {
        case .pending, .resolving, .failed: return true
        case .answered: return false
        }
      }
      let reported = detail("state").flatMap(AgentTreeActivity.init(rawValue:)) ?? .idle
      let status = waiting ? .needsYou : reported
      let label = waiting || section.summary.isEmpty ? status.title : section.summary
      return SubagentChild(
        id: id, sectionID: section.id, title: section.title, agent: detail("agent"),
        goal: detail("goal"), activity: detail("activity"), error: detail("error"),
        status: status, statusLabel: label,
        startedAt: detail("started").flatMap(TimeInterval.init).map(
          Date.init(timeIntervalSince1970:)))
    }
    guard !children.isEmpty else { return nil }
    self.init(children: children)
  }

  /// The children the composer's count lists, in order: see ``AgentTreeActivity/isTallied``.
  public var tally: [SubagentChild] { children.filter(\.status.isTallied) }

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
