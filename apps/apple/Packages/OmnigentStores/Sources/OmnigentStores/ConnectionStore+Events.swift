import OmnigentCoreFFI

extension ConnectionStore {
  func apply(_ event: CoreEvent) {
    eventsApplied += 1
    switch event {
    case .connectionChanged(let phase):
      self.phase = phase
      if case .awaitingBrowserLogin(_, let login) = phase {
        browserLogin = login
      } else {
        browserLogin = nil
      }
      if case .connected(let server) = phase {
        sessionList.viewerID = server.userId
        let list = sessionList
        Task {
          async let projects: Void = list.loadProjects()
          await list.loadHosts(serverURL: server.baseUrl)
          await projects
        }
      }
    case .updatesLinkChanged(let state):
      updatesLink = state
    case .sessionListChanged(let change):
      sessionList.apply(change)
    case .sessionListLoaded:
      sessionList.loaded()
    default:
      applySessionEvent(event)
    }
  }

  private func applySessionEvent(_ event: CoreEvent) {
    switch event {
    case .sessionLinkChanged(let id, let state):
      conversations[id]?.linkChanged(state)
    case .sessionHydrated(let id):
      conversations[id]?.hydrated()
    case .historyPagingChanged(let id, let hasOlder, let isLoading):
      conversations[id]?.historyPagingChanged(hasOlder: hasOlder, isLoading: isLoading)
    case .transcriptReset(let id, let revision, let rows, let header, let sections, let decisions):
      conversations[id]?.reset(
        revision: revision, rows: rows, header: header, sections: sections,
        decisions: decisions)
    case .transcriptChanged(let id, let revision, let change):
      conversations[id]?.apply(revision: revision, change: change)
    case .decisionsChanged(let id, let decisions):
      conversations[id]?.decisions.replace(decisions)
    case .sessionFailure(let id, let message):
      conversations[id]?.failure(message)
    case .sessionClosed(let id):
      conversations[id]?.closed()
    case .sessionSuperseded(let id, let target):
      conversations[id]?.superseded(by: target)
    default:
      applyOtherEvent(event)
    }
  }

  private func applyOtherEvent(_ event: CoreEvent) {
    switch event {
    case .changedFiles(let id, let environment, let update):
      workspaceStores[id]?.changedFilesInvalidated(environmentID: environment, update: update)
      changedFilesRevision += 1
    case .credentialRotated(let expiresAt):
      credentialExpiresAtMs = expiresAt
      credentialRotations += 1
    case .unreadChanged(let ids):
      sessionList.unreadIDs = Set(ids)
    case .terminalsChanged(let id, let rows, let harness):
      terminals(id)?.apply(terminals: rows, harness: harness)
    case .browserActionRequested(let id, let actionID, let action, let args):
      if let browserActions {
        let request = BrowserActionRequest(
          sessionId: id, actionId: actionID, action: action, argsJson: args)
        Task { await browserActions.handle(request) }
      }
    default:
      applyServerEvent(event)
    }
  }

  /// Re-reads the hosts, for the sidebar's Environment detail.
  private func reloadHosts() {
    guard let server = connectedServer else { return }
    let list = sessionList
    Task { await list.loadHosts(serverURL: server.baseUrl) }
  }

  private func applyServerEvent(_ event: CoreEvent) {
    switch event {
    case .notification(let notification):
      notifications?.notify(notification)
    case .badgeChanged(let ids):
      notifications?.badge(ids)
    case .hostsChanged:
      hostsRevision += 1
      reloadHosts()
    case .projectsChanged:
      projectsRevision += 1
      let list = sessionList
      Task { await list.loadProjects() }
    case .unknownUpdate(let frameType):
      unknownUpdates.append(frameType)
      if unknownUpdates.count > 20 { unknownUpdates.removeFirst() }
    case .error(let scope, let error):
      if case .session(let id) = scope, let conversation = conversations[id] {
        conversation.record(error)
      } else {
        record(scope: scope, error)
      }
      if scope == .sessionList { sessionList.failed(error) }
    default:
      break
    }
  }
}
