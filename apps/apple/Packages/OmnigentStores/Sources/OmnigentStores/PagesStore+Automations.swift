import Foundation
import OmnigentCoreFFI

/// The session an automation is created from: each run starts from a copy of it.
public struct AutomationSource: Hashable, Sendable {
  /// The session.
  public var sessionID: String
  /// Its title, the automation's name to start with.
  public var title: String
  /// Its agent, host, folder, model and effort, which the form starts from.
  public var agentID: String?
  /// The host it runs on.
  public var hostID: String?
  /// Its folder.
  public var workspace: String?
  /// Its model.
  public var model: String?
  /// Its effort.
  public var effort: String?

  /// Creates a source.
  public init(
    sessionID: String, title: String, agentID: String? = nil, hostID: String? = nil,
    workspace: String? = nil, model: String? = nil, effort: String? = nil
  ) {
    self.sessionID = sessionID
    self.title = title
    self.agentID = agentID
    self.hostID = hostID
    self.workspace = workspace
    self.model = model
    self.effort = effort
  }
}

extension PagesStore {
  /// Asks the Automations page to open a new automation from `source`.
  public func requestAutomation(from source: AutomationSource) {
    pendingAutomationSource = source
  }

  /// The session the page should make an automation from, once; `nil` when none was asked.
  public func takePendingAutomationSource() -> AutomationSource? {
    defer { pendingAutomationSource = nil }
    return pendingAutomationSource
  }
}

/// The Automations reads beyond the caller's own list: Shared with me, each run's PRs, an
/// automation's grants, the MCP services runs can start with, and which hosts take long
/// trigger messages.
extension PagesStore {
  /// Reads the first page of automations shared with the caller; a reload keeps the list.
  public func loadSharedAutomations() async {
    if sharedAutomations.value == nil { sharedAutomations = .loading }
    do {
      let page = try await core.sharedAutomations(after: nil)
      sharedAutomations = .loaded(page.automations)
      sharedAutomationsCursor = page.nextCursor
    } catch {
      sharedAutomations = .failed(coreError(error))
    }
  }

  /// Reads the next page of shared automations, if any; a failure keeps the rows read.
  public func loadMoreSharedAutomations() async {
    guard let cursor = sharedAutomationsCursor, !isLoadingMoreSharedAutomations else { return }
    isLoadingMoreSharedAutomations = true
    defer { isLoadingMoreSharedAutomations = false }
    do {
      let page = try await core.sharedAutomations(after: cursor)
      let known = sharedAutomations.value ?? []
      let ids = Set(known.map(\.id))
      sharedAutomations = .loaded(known + page.automations.filter { !ids.contains($0.id) })
      sharedAutomationsCursor = page.nextCursor == cursor ? nil : page.nextCursor
    } catch {
      automationError = coreError(error)
    }
  }

  /// Reads the PRs `id`'s newest runs created or worked on; a failure keeps the PRs known.
  public func loadAutomationRunPullRequests(_ id: String) async {
    do {
      let runs = try await core.automationRunPullRequests(id: id)
      automationRunPullRequests[id] = Dictionary(
        runs.map { ($0.runId, $0) }, uniquingKeysWith: { first, _ in first })
    } catch {
      // The run rows stay without PR summaries until a later read lands.
      return
    }
  }

  /// Reads the plans `id`'s newest runs follow; a failure keeps the plans known.
  public func loadAutomationRunSteps(_ id: String) async {
    do {
      let runs = try await core.automationRunSteps(id: id)
      automationRunSteps[id] = Dictionary(
        runs.map { ($0.runId, $0) }, uniquingKeysWith: { first, _ in first })
    } catch {
      // The run rows stay without their tasks until a later read lands.
      return
    }
  }

  /// Reads who `id` is shared with.
  public func loadAutomationGrants(_ id: String) async {
    if automationGrants[id]?.value == nil { automationGrants[id] = .loading }
    do {
      automationGrants[id] = .loaded(try await core.automationGrants(id: id))
    } catch {
      automationGrants[id] = .failed(coreError(error))
    }
  }

  /// Shares `id` with `userID` at read access, then reads the grants again.
  public func grantAutomationAccess(_ id: String, to userID: String) async {
    await changeGrant(id) { try await $0.grantAutomationAccess(id: id, userId: userID) }
  }

  /// Stops sharing `id` with `userID`, then reads the grants again.
  public func revokeAutomationAccess(_ id: String, from userID: String) async {
    await changeGrant(id) { try await $0.revokeAutomationAccess(id: id, userId: userID) }
  }

  /// Clears the last share failure, as the sheet closes.
  public func dismissAutomationGrantError() {
    automationGrantError = nil
  }

  private func changeGrant(_ id: String, _ write: (ClientCore) async throws -> Void) async {
    isSavingAutomationGrant = true
    automationGrantError = nil
    do {
      try await write(core)
    } catch {
      automationGrantError = coreError(error)
    }
    isSavingAutomationGrant = false
    await loadAutomationGrants(id)
  }

  /// Reads the MCP services runs can start with, unless they are loaded.
  public func loadAutomationMcpServices() async {
    if automationMcpServices.value != nil { return }
    automationMcpServices = .loading
    do {
      automationMcpServices = .loaded(try await core.mcpServices())
    } catch {
      automationMcpServices = .failed(coreError(error))
    }
  }

  /// Reads which hosts deliver long session messages, unless known. A failure leaves them
  /// unknown, so triggers keep the shorter budget.
  public func loadLongMessageHosts() async {
    if longMessageHosts.value != nil { return }
    do {
      longMessageHosts = .loaded(Set(try await core.longMessageHosts()))
    } catch {
      longMessageHosts = .failed(coreError(error))
    }
  }

  /// Clears ``automationError`` after the user has seen it.
  public func dismissAutomationError() {
    automationError = nil
  }
}
