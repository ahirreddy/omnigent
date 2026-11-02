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
  ///   - isForking: Whether the request is in flight (or blocked), which disables the sheet.
  ///   - errorMessage: The request's or the catalog's failure.
  /// - Returns: The sheet's state.
  static func state(
    context: ForkContext, plan: ForkPlan, isForking: Bool, errorMessage: String?
  ) -> ForkViewState {
    ForkViewState(
      id: "fork-\(context.source.id)-\(context.upToResponseID ?? "all")", kind: context.kind,
      agents: plan.agents.map {
        OmnigentUIComponents.CreationAgent(
          id: $0.id, name: $0.name, harness: $0.harness, description: $0.description)
      },
      agentID: plan.agentId, directory: plan.directory, isForking: isForking,
      errorMessage: errorMessage, startUnavailableReason: plan.startUnavailableReason)
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
    let forkStart: ForkStart? =
      if start, let hostID = plan.hostId {
        ForkStart(hostId: hostID, workspace: directory)
      } else {
        nil
      }
    return ForkRequest(
      sourceId: context.source.id, upToResponseId: context.upToResponseID,
      agentId: agentID == plan.agentId ? nil : agentID, title: nil, start: forkStart)
  }

  /// The row a "Fork chat from here" cuts after: a settled assistant message with a response.
  /// - Parameter row: The transcript row.
  /// - Returns: Its response id, or `nil` when it cannot be a fork point.
  static func forkPoint(_ row: OmnigentUIComponents.Row) -> String? {
    guard row.role == .assistant, !row.isStreaming, !row.isEphemeral else { return nil }
    return row.responseId
  }
}
