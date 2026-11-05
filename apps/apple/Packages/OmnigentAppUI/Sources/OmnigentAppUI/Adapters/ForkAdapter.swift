import Foundation
import OmnigentCoreFFI
import OmnigentUIComponents

/// What one open fork sheet copies: the source session, the response it is cut after, and the
/// sheet's kind.
struct ForkContext: Equatable {
  /// The session being forked.
  let source: OmnigentCoreFFI.SessionSummary
  /// The last response to copy; `nil` copies the whole session.
  let upToResponseID: String?
  /// The sheet's title and buttons.
  let kind: ForkViewState.Kind
}

/// The fork sheet's view state, from the core's plan and the store's phase, and the request
/// the sheet's choices make.
enum ForkAdapter {
  /// The sheet for `context`.
  /// - Parameters:
  ///   - context: What is being forked.
  ///   - plan: The core's choices for the source.
  ///   - models: The chosen host's models for the chosen agent.
  ///   - isForking: Whether the request is in flight (or blocked), which disables the sheet.
  ///   - errorMessage: The request's or the catalog's failure.
  /// - Returns: The sheet's state.
  static func state(
    context: ForkContext, plan: ForkPlan, models: [ModelChoice] = [], isForking: Bool,
    errorMessage: String?
  ) -> ForkViewState {
    var state = ForkViewState(
      id: "fork-\(context.source.id)-\(context.upToResponseID ?? "all")", kind: context.kind,
      agents: plan.agents.map {
        OmnigentUIComponents.CreationAgent(
          id: $0.id, name: $0.name, harness: $0.harness, description: $0.description)
      },
      agentID: plan.agentId, directory: plan.directory, isForking: isForking,
      errorMessage: errorMessage, startUnavailableReason: plan.startUnavailableReason)
    state.options = options(plan, models: models)
    return state
  }

  /// The host, model and approval choices: Continue keeps the source's host and agent setup.
  static func options(_ plan: ForkPlan, models: [ModelChoice]) -> ForkOptions {
    var modes: [String: [OmnigentUIComponents.ApprovalModeOption]] = [:]
    for agent in plan.agents {
      if let menu = creationApprovalModeMenu(agent: agent) {
        modes[agent.id] = ComposerAdapter.approvalModes(menu).options
      }
    }
    return ForkOptions(
      hosts: plan.hosts.map {
        ForkHostOption(id: $0.hostId, name: $0.name, unavailableReason: $0.unavailableReason)
      },
      offersSandbox: plan.offersSandbox, models: NewSessionAdapter.models(models),
      approvalModes: modes)
  }

  /// The request for the sheet's choices. Keeping the source's agent sends no agent, and a
  /// start launches on the plan's host in `directory`.
  /// - Parameters:
  ///   - context: What is being forked.
  ///   - plan: The core's choices for the source.
  ///   - agentID: The chosen agent.
  ///   - directory: The chosen directory.
  ///   - start: Whether to start the fork ("Clone & start").
  /// - Returns: The request.
  static func request(
    context: ForkContext, plan: ForkPlan, agentID: String, directory: String, start: Bool
  ) -> ForkRequest {
    request(
      context: context, plan: plan,
      choices: ForkChoices(agentID: agentID, directory: directory, start: start))
  }

  /// The request for every choice in the sheet: a start on the chosen host (else the
  /// source's) with an optional worktree branch, or a new sandbox, and the run configuration.
  static func request(context: ForkContext, plan: ForkPlan, choices: ForkChoices) -> ForkRequest {
    let branch = choices.branch.trimmingCharacters(in: .whitespaces)
    let forkStart: ForkStart? =
      if choices.start, !choices.isSandbox, let hostID = choices.hostID ?? plan.hostId {
        ForkStart(
          hostId: hostID, workspace: choices.directory, branch: branch.isEmpty ? nil : branch)
      } else {
        nil
      }
    let title = choices.title.trimmingCharacters(in: .whitespaces)
    return ForkRequest(
      sourceId: context.source.id, upToResponseId: context.upToResponseID,
      agentId: choices.agentID == plan.agentId ? nil : choices.agentID,
      title: title.isEmpty ? nil : title, start: forkStart,
      // The sandbox inherits the original's repositories until the sheet's picker sets them.
      sandbox: choices.isSandbox
        ? ForkSandbox(provider: choices.sandboxProvider, workspaces: nil) : nil,
      model: choices.model, reasoningEffort: choices.effort, approvalMode: choices.approvalMode,
      agent: choices.approvalMode == nil ? nil : plan.agents.first { $0.id == choices.agentID })
  }

  /// The row a "Fork chat from here" cuts after: a settled assistant message with a response.
  /// - Parameter row: The transcript row.
  /// - Returns: Its response id, or `nil` when it cannot be a fork point.
  static func forkPoint(_ row: OmnigentUIComponents.Row) -> String? {
    guard row.role == .assistant, !row.isStreaming, !row.isEphemeral else { return nil }
    return row.responseId
  }
}
