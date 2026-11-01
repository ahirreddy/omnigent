import Foundation

extension PreviewData {
  /// A `child-<id>` section shaped like the core's (`state`, `goal`, `activity`, `agent`,
  /// `started`, `id` details).
  static func childSection(
    _ id: String, title: String, state: SubagentStatus, agent: String? = nil,
    goal: String? = nil, activity: String? = nil, error: String? = nil, startedAgo: Int = 120
  ) -> EventSection {
    var details = [DetailSection(id: "state", title: "State", text: state.rawValue)]
    func add(_ key: String, _ label: String, _ value: String?) {
      if let value { details.append(DetailSection(id: key, title: label, text: value)) }
    }
    add("goal", "Goal", goal)
    add("activity", "Latest", activity)
    add("agent", "Agent", agent)
    add("error", "Error", error)
    let started = Int(now.timeIntervalSince1970) - startedAgo
    details.append(DetailSection(id: "started", title: "Started", text: "\(started)"))
    details.append(DetailSection(id: "id", title: "Session ID", text: id))
    return EventSection(
      id: "child-\(id)", title: title, summary: state.title, details: details, sessionId: id)
  }

  /// The blocked child's request, mirrored into the parent.
  static let subagentCommand = DecisionCard(
    id: "elic_child_cmd", carryingSessionId: sessionID, targetSessionId: "sess_c3",
    title: "Approval requested", detail: "Run the migration check.",
    kind: .approval,
    permissions: PermissionOptions(
      command: CommandApproval(
        command: "cargo run -p omnigent-cli -- migrate --check", cwd: "/workspace/omnigent",
        reason: "Confirm the schema is current"),
      persistModes: [.session]))

  /// A parent with three sub-agents: one running, one blocked on a request, one done.
  static var subagentConversation: ConversationViewState {
    var state = shellConversation
    state.sections.removeAll { $0.id.hasPrefix("child-") }
    state.sections += [
      childSection(
        "sess_c1", title: "Write auth tests", state: .running, agent: "tester",
        goal: "Cover expiry and concurrent refresh in auth/tests.rs.",
        activity: "Running cargo test -p omnigent-core auth", startedAgo: 260),
      childSection(
        "sess_c3", title: "Check migrations", state: .running, agent: "Codex",
        goal: "Make sure the session schema migration is current.",
        activity: "Waiting for approval to run the migration check", startedAgo: 140),
      childSection(
        "sess_c2", title: "Review patch", state: .ready, agent: "reviewer",
        goal: "Review the refresh patch for races.",
        activity: "No blocking issues. Two naming nits.", startedAgo: 900),
    ]
    state.decisions = [subagentCommand]
    state.header.status = .running
    state.revision += 1
    return state
  }

  /// A child's own transcript, opened from the parent: it routes back.
  static var childConversation: ConversationViewState {
    var state = conversation
    state.header = SessionHeader(
      id: "sess_c1", title: "Write auth tests", status: .running,
      settings: SessionSettings(harness: "claude-native", parentId: sessionID))
    state.sections = []
    state.decisions = []
    return state
  }
}
