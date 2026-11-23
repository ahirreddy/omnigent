import OmnigentCoreFFI

extension ConnectionStore {
  func apply(_ event: CoreEvent) {
    eventsApplied += 1
    defer { if !eventWaiters.isEmpty { resumeEventWaiters() } }
    logSavedCopyFailure(event)
    guard SidebarLoadSignposts.isEnabled, let kind = SidebarLoadSignposts.kind(of: event) else {
      applyEvent(event)
      return
    }
    SidebarLoadSignposts.measure("list event", detail: { _ in kind }, { applyEvent(event) })
  }

  private func applyEvent(_ event: CoreEvent) {
    switch event {
    case .connectionChanged(let phase):
      connectionChanged(phase)
      observeReachability()
    case .updatesLinkChanged(let state):
      if state != updatesLink { updatesLink = state }
      observeReachability()
    case .sessionListChanged(let change):
      sessionList.apply(change)
    case .sessionListLoaded:
      sessionList.loaded()
    case .offlineChanged(let serverURL):
      offlineChanged(serverURL)
      observeReachability()
    case .savedListShown(let serverURL, let viewerID):
      savedListShown(serverURL, viewerID: viewerID)
    case .sessionOfflineChanged(let id, let offline):
      conversations[id]?.offlineChanged(offline)
    default:
      applySessionEvent(event)
    }
  }

  /// Discovers `serverURL`, then connects: a saved credential is used when there is one,
  /// otherwise ``phase`` becomes `signInRequired` with the methods to offer.
  /// - Parameters:
  ///   - serverURL: The server URL as typed.
  ///   - expectedUserID: The account to restore on an accounts server.
  public func connect(serverURL: String, expectedUserID: String? = nil) async {
    await discover(serverURL: serverURL)
    guard let core, discovery != nil else { return }
    core.setAdminView(enabled: AdminViewPreference.isOn(for: serverURL))
    do {
      let connected = try await core.connect(serverUrl: serverURL, expectedUserId: expectedUserID)
      // The phases the core passed through are still on their way here: applied after its
      // answer, one of them would show the connection as not made until the last arrives.
      await eventsSentSoFarApplied()
      phase = connected
      observeReachability()
    } catch {
      record(scope: .connection, coreError(error))
    }
  }

  /// Returns once every event the core has sent by now is applied. The core changes a row
  /// before it answers a call, and the answer can overtake that event on its way here.
  func eventsSentSoFarApplied() async {
    let target = relay.eventsSent
    guard eventsApplied < target else { return }
    await withCheckedContinuation { eventWaiters.append((target, $0)) }
  }

  private func resumeEventWaiters() {
    let reached = eventWaiters.filter { $0.target <= eventsApplied }
    eventWaiters.removeAll { $0.target <= eventsApplied }
    for waiter in reached { waiter.resume.resume() }
  }

  private func connectionChanged(_ phase: ConnectionPhase) {
    if phase != self.phase { self.phase = phase }
    if case .awaitingBrowserLogin(_, let login) = phase {
      browserLogin = login
    } else if browserLogin != nil {
      browserLogin = nil
    }
    // A routine reconnect passes through other phases; this one means the connection ended.
    // Open conversations stay: the core reopens them on the next connect.
    if phase == .disconnected { sessionList.clear() }
    if case .connected(let server) = phase {
      accountConnected(server.userId)
      sessionList.viewerID = server.userId
      markSavedDrafts()
      loadServerLists(server)
      reloadOfferedPages()
    }
  }

  private func applySessionEvent(_ event: CoreEvent) {
    switch event {
    case .sessionLinkChanged(let id, let state):
      conversations[id]?.linkChanged(state)
      tasksStores[id]?.linkChanged(state)
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
      countFileChange(in: id)
    case .credentialRotated(let expiresAt):
      credentialExpiresAtMs = expiresAt
      credentialRotations += 1
      reloadOfferedPages()
    case .unreadChanged(let ids):
      let unread = Set(ids)
      if unread != sessionList.unreadIDs { sessionList.unreadIDs = unread }
    case .sessionListPagingChanged, .projectsLoaded, .projectsFailed, .projectFoldersChanged,
      .projectFolderFailed:
      applyListPagesEvent(event)
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

  /// The list's pages, the projects and their folders, as the core read them.
  private func applyListPagesEvent(_ event: CoreEvent) {
    switch event {
    case .sessionListPagingChanged(let hasMore, let isLoading):
      sessionList.paging.pagingChanged(hasMore: hasMore, isLoading: isLoading)
    case .projectsLoaded(let projects, let sortMode):
      sessionList.projectsLoaded(projects, sortMode: sortMode)
    case .projectsFailed(let error):
      sessionList.projectsError = error
    case .projectFoldersChanged(let folders):
      sessionList.paging.foldersChanged(folders)
    case .projectFolderFailed(let folderID, let error):
      sessionList.paging.folderFailed(folderID, error)
    default:
      break
    }
  }

  /// Reads the hosts of a server just connected to; the core reads its projects.
  private func loadServerLists(_ server: ConnectedServer) {
    let list = sessionList
    let offlineHosts = notifications?.offlineHosts
    Task {
      let hosts = await list.loadHosts(serverURL: server.baseUrl)
      offlineHosts?.observe(hosts)
    }
  }

  /// Re-reads the hosts, for the sidebar's Environment detail and host-offline notifications.
  func reloadHosts() {
    guard let server = connectedServer else { return }
    let list = sessionList
    let offlineHosts = notifications?.offlineHosts
    Task {
      let hosts = await list.loadHosts(serverURL: server.baseUrl)
      offlineHosts?.observe(hosts)
    }
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
      // The core reads the projects again; `projectsLoaded` brings them.
      projectsRevision += 1
    case .unknownUpdate(let frameType):
      unknownUpdates.append(frameType)
      if unknownUpdates.count > 20 { unknownUpdates.removeFirst() }
    case .error(let scope, let error):
      if case .session(let id) = scope, let conversation = conversations[id] {
        conversation.recordStreamFailure(error)
      } else {
        record(scope: scope, error)
      }
      if scope == .sessionList { sessionList.failed(error) }
    default:
      applyTasksEvent(event)
    }
  }

  /// An entry pushed to an open session's journal goes to its Tasks tab; the muted sessions
  /// with unseen activity go to the list, for their menus' Mark as read.
  private func applyTasksEvent(_ event: CoreEvent) {
    switch event {
    case .sessionJournalAppended(let id, let entry):
      tasksStores[id]?.journalAppended(entry)
    case .mutedUnseenChanged(let ids):
      let unseen = Set(ids)
      if unseen != mutedUnseenIDs { mutedUnseenIDs = unseen }
    default:
      break
    }
  }
}
