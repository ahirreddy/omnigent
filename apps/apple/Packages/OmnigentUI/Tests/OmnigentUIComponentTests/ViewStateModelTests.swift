import Foundation
import Testing

@testable import OmnigentUIComponents

/// The rules view state carries for the views that read it.
@Suite("View state: rules")
struct ViewStateModelTests {
  @Test("A host is available only when online and not a managed sandbox")
  func hostAvailability() {
    let online = CreationHost(hostId: "h", name: "H", status: "online")
    #expect(online.isAvailable)
    #expect(online.id == "h")
    #expect(!CreationHost(hostId: "h", name: "H", status: "offline").isAvailable)
    #expect(
      !CreationHost(hostId: "h", name: "H", status: "online", sandboxProvider: "e2b").isAvailable)
  }

  @Test("A load phase gives its value, its failure, and whether it is in flight")
  func loadPhase() {
    #expect(LoadPhase<Int>.loaded(3).value == 3)
    #expect(LoadPhase<Int>.idle.value == nil)
    #expect(LoadPhase<Int>.loading.isLoading)
    #expect(!LoadPhase<Int>.loaded(3).isLoading)
    #expect(LoadPhase<Int>.failed(message: "no").errorMessage == "no")
    #expect(LoadPhase<Int>.loading.errorMessage == nil)
  }

  @Test("The sidebar finds its current server and counts pins")
  func sidebar() {
    let sessions = [
      SessionSummary(id: "a", title: "A", isPinned: true),
      SessionSummary(id: "b", title: "B"),
    ]
    var state = SidebarViewState(
      list: SessionListViewState(sessions: sessions),
      servers: [ServerChoice(id: "s", name: "Server", url: "https://s")], currentServerID: "s")
    #expect(state.currentServer?.name == "Server")
    #expect(state.pinnedCount == 1)
    state.currentServerID = "gone"
    #expect(state.currentServer == nil)
  }

  @Test("The sidebar's menus name their choices")
  func sidebarWords() {
    #expect(
      SessionShowScope.allCases.map(\.title) == [
        "All sessions", "My sessions", "Shared sessions", "Archived sessions",
      ])
    #expect(
      SessionGrouping.allCases.map(\.title) == [
        "Default", "Status", "Harness", "Created", "Updated",
      ])
    #expect(SessionSort.allCases.map(\.title) == ["Updated", "Created"])
    #expect(
      SessionRowDetail.allCases.map(\.title) == ["Updated", "Environment", "Repo", "Branch"])
    #expect(
      SessionFilter.allCases.map(\.title) == ["All sessions", "Running", "Needs you", "Archived"])
    #expect(Set(SessionFilter.allCases.map(\.systemImage)).count == SessionFilter.allCases.count)
    #expect(SessionFilter.running.id == .running)
  }

  @Test("A summary derives its attention, unless told, and its date")
  func summary() {
    #expect(SessionSummary(id: "a", title: "A", status: .running).attention == .working)
    #expect(SessionSummary(id: "a", title: "A", failureMessage: "x").attention == .failed)
    #expect(SessionSummary(id: "a", title: "A", attention: .unread).attention == .unread)
    let dated = SessionSummary(id: "a", title: "A", updatedAt: 60)
    #expect(dated.updatedDate == Date(timeIntervalSince1970: 60))
  }

  @Test("Moving a project goes where it says, and refuses a move that changes nothing")
  func moveProject() {
    let projects = ["a", "b", "c"].map { SessionProject(id: $0, name: $0, sessionIds: []) }
    func moved(_ id: String, _ move: ProjectMove) -> [String] {
      SessionProject.moved(projects, id: id, move).map(\.id)
    }
    #expect(moved("b", .upOne) == ["b", "a", "c"])
    #expect(moved("b", .downOne) == ["a", "c", "b"])
    #expect(moved("c", .top) == ["c", "a", "b"])
    #expect(moved("a", .bottom) == ["b", "c", "a"])
    #expect(moved("a", .upOne).isEmpty)
    #expect(moved("c", .downOne).isEmpty)
    #expect(moved("a", .top).isEmpty)
    #expect(moved("c", .bottom).isEmpty)
    #expect(moved("gone", .top).isEmpty)
  }

  @Test("Archived retention expires only what the caller may delete and is past the cutoff")
  func retentionExpiry() {
    let now = Date(timeIntervalSince1970: 100 * 86_400)
    let sessions = ["old", "mine", "new", "unknown"].map { SessionSummary(id: $0, title: $0) }
    let info = [
      "old": ArchivedSessionInfo(archivedAt: 0, canDelete: false),
      "mine": ArchivedSessionInfo(projectID: "p", archivedAt: 0, canDelete: true),
      "new": ArchivedSessionInfo(archivedAt: 99 * 86_400, canDelete: true),
    ]
    #expect(ArchivedRetention.expired(sessions, info: info, days: 7, now: now) == ["mine"])
    #expect(ArchivedRetention.expired(sessions, info: info, days: nil, now: now).isEmpty)
    // A stored value too large to be a time span keeps everything.
    #expect(ArchivedRetention.expired(sessions, info: info, days: .max, now: now).isEmpty)
  }

  @Test("A decision response says what happened and whether it outlives this request")
  func decisionResponses() {
    let oneShot: [(DecisionResponse, String)] = [
      (.approve, "Approved"), (.decline, "Rejected"), (.cancel, "Dismissed"),
      (.answer(value: "Yes"), "Answered: Yes"), (.form(values: [:]), "Answers submitted"),
      (.declineWithFeedback(feedback: "no"), "Rejected \u{00B7} reply sent to the agent"),
    ]
    let standing: [(DecisionResponse, String)] = [
      (.approveAllEdits, "Approved \u{00B7} all edits allowed"),
      (.approveAutoMode, "Approved \u{00B7} auto mode"),
      (.approveDirectories, "Approved for these directories"),
      (.approveRemembering, "Approved and remembered"),
      (.approveCommandPolicy(policy: ["ls"]), "Approved with the command policy"),
      (.approvePersist(mode: .always), "Always allowed"),
      (.approvePersist(mode: .session), "Approved for this session"),
    ]
    for (response, summary) in oneShot {
      #expect(response.summary == summary)
      #expect(!response.changesStandingPermissions, "\(summary)")
    }
    for (response, summary) in standing {
      #expect(response.summary == summary)
      #expect(response.changesStandingPermissions, "\(summary)")
    }
  }

  @Test("Persist is offered by mode, or by an always-allow pattern")
  func persistOffers() {
    #expect(PermissionOptions(persistModes: [.session]).offersPersist(.session))
    #expect(!PermissionOptions(persistModes: [.session]).offersPersist(.always))
    let pattern = AntigravityPermission(alwaysAllowPattern: "ls *")
    #expect(PermissionOptions(antigravity: pattern).offersPersist(.always))
    #expect(!PermissionOptions(antigravity: AntigravityPermission()).offersPersist(.always))
  }

  @Test("A card is mirrored when it carries another session's request")
  func mirroredCard() {
    let own = DecisionCard(
      id: "c", carryingSessionId: "s", title: "T", detail: "", kind: .approval)
    #expect(!own.isMirrored)
    #expect(own.targetSessionId == "s")
    let mirrored = DecisionCard(
      id: "c", carryingSessionId: "s", targetSessionId: "child", title: "T", detail: "",
      kind: .approval)
    #expect(mirrored.isMirrored)
  }

  @Test("A card's phase is what was recorded; otherwise whether it was answered")
  func cardPhases() {
    let pending = DecisionCard(
      id: "p", carryingSessionId: "s", title: "T", detail: "", kind: .approval)
    let answered = DecisionCard(
      id: "a", carryingSessionId: "s", title: "T", detail: "", kind: .approval, answered: true)
    let recorded = DecisionCard(
      id: "r", carryingSessionId: "s", title: "T", detail: "", kind: .approval)
    let confirming = DecisionCard(
      id: "c", carryingSessionId: "s", title: "T", detail: "", kind: .approval)
    let state = ConversationViewState(
      header: SessionHeader(id: "s", title: "S"),
      decisions: [pending, answered, recorded, confirming],
      decisionPhases: ["r": .resolving, "c": .answered(summary: "Approved")],
      sections: [EventSection(id: "one", title: "One", summary: "")])
    #expect(state.phase(of: pending) == .pending)
    #expect(state.phase(of: answered) == .answered(summary: "Response sent"))
    #expect(state.phase(of: recorded) == .resolving)
    #expect(state.phase(of: confirming) == .answered(summary: "Approved"))
    // A card showing its answer while the server confirms no longer needs the user.
    #expect(state.pendingDecisions.map(\.id) == ["p", "r"])
    #expect(state.section("one")?.id == "one")
    #expect(state.section("two") == nil)
  }

  @Test("A pull request's status ranks what needs the user first and names itself")
  func pullRequestStatuses() {
    typealias Status = PullRequestSummary.Status
    let ranked: [(Status, String)] = [
      (.conflicts, "Merge conflicts"), (.failing, "Checks failing"), (.ready, "Ready to merge"),
      (.running, "Checks running"), (.open, "Open"), (.draft, "Draft"),
      (.unknown, "Not checked yet"), (.merged, "Merged"), (.closed, "Closed"),
    ]
    #expect(ranked.count == Status.allCases.count)
    #expect(ranked.map(\.0.priority) == Array(0..<ranked.count))
    #expect(ranked.allSatisfy { $0.0.title == $0.1 })
  }

  @Test("The model label prefers the override, by its row's name, then the base model")
  func modelLabel() {
    let options = [ModelOption(id: "m", model: "wire-m", displayName: "Model M")]
    func label(_ override: ReportedValue, base: String? = nil) -> String {
      SessionSettings(modelOverride: override, baseModel: base, modelOptions: options).modelLabel
    }
    #expect(label(.value(value: "m")) == "Model M")
    #expect(label(.value(value: "wire-m")) == "Model M")
    #expect(label(.value(value: "other")) == "other")
    #expect(label(.harnessDefault, base: "Base") == "Base")
    #expect(label(.notReported) == "Default model")
  }

  @Test("A fork's dialog title and verb match what is being forked")
  func forkWords() {
    func fork(_ kind: ForkViewState.Kind) -> ForkViewState {
      ForkViewState(id: "f", kind: kind, agents: [], agentID: "", directory: "")
    }
    #expect(fork(.session).title == "Clone session")
    #expect(fork(.session).verb == "Clone")
    #expect(fork(.fromMessage(rowID: "r")).title == "Fork from this response")
    #expect(fork(.fromMessage(rowID: "r")).verb == "Fork")
    #expect(fork(.anotherDirectory).title == "Continue in another directory")
    #expect(fork(.anotherDirectory).verb == "Continue")
  }

  @Test("A policy template matches on its name or detail, ignoring case and blanks")
  func policyMatch() {
    let template = PolicyTemplate(
      id: "t", name: "Budget limit", detail: "Stops spending", suggestedName: "budget", params: [])
    #expect(template.matches("   "))
    #expect(template.matches(" budget "))
    #expect(template.matches("SPENDING"))
    #expect(!template.matches("network"))
  }

  @Test("The transcript's status skips activity rows and reads the last row and running tool")
  func transcriptStatus() {
    #expect(TranscriptStatus(rows: []).isEmpty)
    #expect(TranscriptStatus(rows: []).activityTitle == nil)
    #expect(!TranscriptStatus(rows: []).lastInterrupted)
    let running = Activity(kind: .toolCall, title: "Reading", status: "in_progress")
    let done = Activity(kind: .toolCall, title: "Done", status: "completed")
    let rows = [
      Row(id: "a", role: .tool, activity: done),
      Row(id: "b", role: .tool, activity: running),
      Row(id: "c", role: .assistant, interrupted: true),
      Row(id: "d", role: .assistant, isActivityOnly: true),
    ]
    let status = TranscriptStatus(rows: rows)
    #expect(!status.isEmpty)
    #expect(status.lastInterrupted)
    #expect(status.activityTitle == "Reading")
    #expect(TranscriptStatus(rows: [Row(id: "d", role: .assistant, isActivityOnly: true)]).isEmpty)
  }

  @Test("An agent's help line adds the detail behind a status; each role has its own symbol")
  func agentNode() {
    #expect(AgentTreeNode(id: "a", name: "A", statusLabel: "Idle").statusHelp == "Idle")
    #expect(
      AgentTreeNode(id: "a", name: "A", statusLabel: "Failed", statusDetail: "closed").statusHelp
        == "Failed: closed")
    #expect(Set(AgentTreeRole.allCases.map(\.systemImage)).count == AgentTreeRole.allCases.count)
  }

  @Test("The repository chip reads none, the one repository's name, or a count")
  func repositoriesLabel() {
    let one = SandboxRepoChoice(url: "https://x/y")
    func label(_ repos: [SandboxRepoChoice]) -> String {
      SandboxRepositoriesState(repos: repos).label { _ in "y" }
    }
    #expect(label([]) == "No repository")
    #expect(label([one]) == "y")
    #expect(label([one, SandboxRepoChoice(url: "https://x/z")]) == "2 repositories")
  }
}
