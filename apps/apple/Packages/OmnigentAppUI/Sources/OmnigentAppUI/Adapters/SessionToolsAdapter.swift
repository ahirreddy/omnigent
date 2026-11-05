import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import SwiftUI

/// The composer's Add (+) menu tools (side chat, goal, plan mode) and the tray's task
/// indicators (pull requests, background tasks, sub-agents, goal), over the conversation's
/// stores. Which tools a session offers is the core's rule.
enum SessionToolsAdapter {
  /// What the Add menu and the tray need from the screen around the composer.
  struct Routes {
    /// Opens a session's chat (a side chat or a sub-agent) next to this one.
    var openSession: @MainActor (String) -> Void
    /// Shows the right panel's Pull Requests tab.
    var showPullRequests: @MainActor () -> Void
    /// Opens the goal sheet.
    var showGoal: @MainActor () -> Void
    /// Shows a failure.
    var report: @MainActor (String) -> Void
  }

  /// How the session takes a goal, or `nil` when it has no goal control.
  static func goalControl(_ store: ConversationStore, summary: OmnigentCoreFFI.SessionSummary?)
    -> GoalControl?
  {
    let settings = store.header?.settings
    return OmnigentCoreFFI.goalControl(
      wrapper: settings?.wrapper, harness: settings?.harness, agentName: summary?.agentName,
      parentId: settings?.parentId)
  }

  /// Codex plan mode, where it applies.
  struct PlanMode: Equatable {
    /// It is on.
    var isOn: Bool
  }

  /// Codex plan mode, or `nil` when the session has none.
  static func planMode(_ store: ConversationStore) -> PlanMode? {
    codexPlanMode(
      wrapper: store.header?.settings?.wrapper,
      collaborationMode: store.sections.first { $0.id == "collaboration" }?.summary
    ).map(PlanMode.init)
  }

  /// Adds the Add menu's Side chat, Goal and Plan, and the tray indicators' actions.
  static func add(
    to extras: inout ComposerExtraActions, store: ConversationStore,
    summary: OmnigentCoreFFI.SessionSummary?, routes: Routes
  ) {
    let tools = store.tools
    let readOnly = ComposerAdapter.isReadOnly(store)
    extras.newSideChat = sideChat(store, routes: routes)
    switch goalControl(store, summary: summary) {
    case .managed: extras.setGoal = routes.showGoal
    case .command: if !readOnly { extras.setGoal = routes.showGoal }
    case nil: break
    }
    if let isOn = planMode(store)?.isOn, !readOnly {
      extras.isPlanOn = isOn
      extras.togglePlan = {
        guard !tools.isBusy else { return }
        Task {
          await tools.setPlanMode(!isOn)
          if let error = tools.lastError {
            routes.report("Could not \(isOn ? "exit" : "enter") Plan mode: \(error.message)")
          }
        }
      }
    }
    extras.indicators = ComposerIndicatorActions(
      openPullRequests: routes.showPullRequests, openSubagent: routes.openSession,
      openGoal: extras.setGoal)
  }

  /// Side chat, for a session the viewer can write to whose harness is known (web
  /// `supportsSideChat`); `nil` hides it.
  static func sideChat(_ store: ConversationStore, routes: Routes) -> (@MainActor () -> Void)? {
    guard !ComposerAdapter.isReadOnly(store), store.header?.settings?.harness?.isEmpty == false
    else { return nil }
    return { startSideChat(store, routes: routes) }
  }

  /// Starts a side chat: a native `/side` fills the composer, a forked one opens next to this
  /// chat.
  static func startSideChat(_ store: ConversationStore, routes: Routes) {
    let tools = store.tools
    guard !tools.isBusy else { return }
    Task {
      switch await tools.startSideChat() {
      case .command(let prefix): store.composer.text = prefix
      case .session(let sessionID): routes.openSession(sessionID)
      case nil:
        let reason = tools.lastError?.message ?? "Unknown error."
        routes.report("Couldn't start a side chat for this session: \(reason)")
      }
    }
  }

  /// The tray's task indicators.
  /// - Parameters:
  ///   - store: The conversation.
  ///   - screen: The screen's state, for the sub-agent sections and their requests.
  /// - Returns: The indicators.
  static func indicators(_ store: ConversationStore, screen: ConversationViewState)
    -> ComposerTaskIndicators
  {
    let background = store.sections.first { $0.id == "status" }?.details
      .first { $0.id == "background" }.flatMap { Int($0.text) }
    return ComposerTaskIndicators(
      backgroundTasks: background ?? 0,
      subagents: SubagentGroup(state: screen)?.active ?? [],
      goal: store.tools.goal.map(goal))
  }

  /// "#1234", or "3 PRs"; `nil` without linked pull requests.
  /// The composer chip's linked PRs with their live status, the ones that need the user first
  /// (the web's order); equal statuses keep the server's order.
  static func pullRequestPreview(_ panel: SessionPanelStore?) -> [PullRequestSummary] {
    guard let panel, case .loaded(let rows, _) = PullRequestAdapter.state(panel) else { return [] }
    return rows.enumerated()
      .sorted { ($0.element.status.priority, $0.offset) < ($1.element.status.priority, $1.offset) }
      .map(\.element)
  }

  /// Puts the linked PRs' label, top status and hover preview on the composer tray.
  static func setPullRequests(
    _ panel: SessionPanelStore?, label: String?, on tray: inout ComposerTray
  ) {
    tray.pullRequest = label
    tray.pullRequestPreview = pullRequestPreview(panel)
    tray.pullRequestStatus = tray.pullRequestPreview.first?.status
  }

  static func pullRequestLabel(_ panel: SessionPanelStore?) -> String? {
    guard case .loaded(let list) = panel?.pullRequests else { return nil }
    switch list.pullRequests.count {
    case 0: return nil
    case 1: return list.pullRequests.first.map { "#\($0.number)" }
    case let count: return "\(count) PRs"
    }
  }

  static func goal(_ goal: SessionGoal) -> ComposerGoal {
    ComposerGoal(
      objective: goal.objective, status: goal.status,
      usage: ComposerGoal.usage(
        tokensUsed: goal.tokensUsed, tokenBudget: goal.tokenBudget,
        seconds: goal.timeUsedSeconds),
      tokenBudget: goal.tokenBudget, canPause: goal.canPause, canResume: goal.canResume)
  }

  /// The goal sheet for the session's goal control, `nil` when it has none.
  static func goalSheet(
    _ store: ConversationStore, summary: OmnigentCoreFFI.SessionSummary?
  ) -> GoalSheetState? {
    let tools = store.tools
    let mode: GoalSheetState.Mode
    switch goalControl(store, summary: summary) {
    case .managed: mode = .managed(goal: tools.goal.map(goal))
    case .command(let backend): mode = .command(backend: backend)
    case nil: return nil
    }
    return GoalSheetState(
      mode: mode, isBusy: tools.isBusy, errorMessage: tools.lastError?.message,
      isReadOnly: ComposerAdapter.isReadOnly(store))
  }

  /// The goal sheet's actions: save, pause or clear a managed goal; send a command goal.
  static func goalActions(
    _ store: ConversationStore, summary: OmnigentCoreFFI.SessionSummary?,
    dismiss: @escaping @MainActor () -> Void, report: @escaping @MainActor (String) -> Void
  ) -> GoalSheetActions {
    let tools = store.tools
    guard case .managed = goalControl(store, summary: summary) else {
      return GoalSheetActions(
        submit: { condition, _ in
          guard let command = goalCommand(condition: condition) else { return }
          let composer = store.composer
          // The goal goes out as a message; a draft in progress is never sent with it.
          guard composer.text.isEmpty, composer.attachments.items.isEmpty else {
            report("Send or clear the message you are writing before starting a goal.")
            return
          }
          composer.text = command
          dismiss()
          Task { await composer.send() }
        }, dismiss: dismiss)
    }
    return GoalSheetActions(
      submit: { objective, budget in
        Task {
          let isNew = tools.goal == nil
          if await tools.saveGoal(objective: objective, tokenBudget: budget, activate: isNew) {
            dismiss()
          }
        }
      },
      setActive: { active in Task { await tools.setGoalActive(active) } },
      clear: {
        Task {
          await tools.clearGoal()
          if tools.lastError == nil { dismiss() }
        }
      },
      dismiss: {
        tools.dismissError()
        dismiss()
      })
  }
}

/// Reads a managed goal once the session's harness is known, and presents the goal sheet.
struct SessionGoalPresenter: ViewModifier {
  let conversation: ConversationStore
  let summary: OmnigentCoreFFI.SessionSummary?
  @Binding var isPresented: Bool
  let report: @MainActor (String) -> Void

  func body(content: Content) -> some View {
    content
      .task(id: conversation.header?.settings?.wrapper) {
        if case .managed = SessionToolsAdapter.goalControl(conversation, summary: summary) {
          await conversation.tools.loadGoal()
        }
      }
      .sheet(isPresented: $isPresented) {
        if let goal = SessionToolsAdapter.goalSheet(conversation, summary: summary) {
          GoalSheet(
            state: goal,
            actions: SessionToolsAdapter.goalActions(
              conversation, summary: summary, dismiss: { isPresented = false }, report: report)
          )
          // The fields start from the goal, so they refill once it has been read.
          .id(conversation.tools.isGoalLoaded)
        }
      }
  }
}
