import Combine
import Foundation
import NativeLabCore

@MainActor
final class AppModel: ObservableObject {
  @Published private(set) var conversations: [String: ConversationState] = [:]
  @Published private(set) var isRefreshing = false
  @Published private(set) var listError: String?
  @Published private(set) var drafts: [String: String] = [:]
  @Published private(set) var errors: [String: String] = [:]
  @Published private(set) var sendingSessionIDs: Set<String> = []
  @Published private(set) var stoppingSessionIDs: Set<String> = []
  @Published private(set) var resolvingDecisionIDs: Set<String> = []
  @Published private(set) var editingSessionIDs: Set<String> = []
  @Published private(set) var storageError: String?
  @Published private(set) var isLive = false
  @Published private(set) var isConnecting = false
  @Published private(set) var connectionError: String?
  @Published private(set) var serverIdentity = ""
  @Published private(set) var connectedServerURL = ""
  @Published private(set) var connectionGeneration = UUID()
  @Published private(set) var isLoadingMoreSessions = false
  @Published private(set) var hasMoreSessions = false
  @Published private(set) var isLoadingInbox = false
  @Published private(set) var inboxError: String?
  @Published private(set) var connectionStatus = "Offline sample workspace"
  @Published private(set) var isReconnecting = false
  @Published private(set) var deliveryNotices: [String: String] = [:]
  @Published private(set) var uncertainDeliverySessionIDs: Set<String> = []
  @Published private var configurationOperations: Set<String> = []
  @Published private var uncertainConfigurationOperations: Set<String> = []
  @Published private var liveInventory: [String: SessionSummary] = [:]
  @Published private var readySessionIDs: Set<String> = []
  @Published private var streamStatuses: [String: String] = [:]
  @Published private var liveSummaries: [String: SessionSummary] = [:]
  @Published private var loadingHistoryIDs: Set<String> = []
  @Published private var historyCursors: [String: String] = [:]
  @Published var localServerURL = "http://127.0.0.1:6767"
  @Published private var uncertainCreationScopes: Set<String> = []
  @Published private var creatingScopes: Set<String> = []
  let attachmentDrafts = AttachmentDraftStore()
  private var attachmentObservation: AnyCancellable?

  private let demoClient: DemoSessionClient
  private var client: any SessionClient
  private var liveClient: LocalServerSessionClient?
  private let store: LocalWorkspaceStore?
  private var demoConversations: [String: ConversationState] = [:]
  private var demoDrafts: [String: String] = [:]
  private var updatesTask: Task<Void, Never>?
  private var activityTask: Task<Void, Never>?
  private var inventoryTask: Task<Void, Never>?
  private var saveTask: Task<Void, Never>?
  private var liveDrafts: [String: [String: String]] = [:]
  private var submissionLedger = SubmissionLedger()
  private var pendingSubmissions: [String: MessageSubmission] = [:]
  private var consumedItemIDs: [String: Set<String>] = [:]
  private var consumedPendingIDs: [String: Set<String>] = [:]
  private var inventoryChanges: [String: SessionSummary] = [:]
  private var inventoryRemovals: Set<String> = []
  private var listChanges: [String: SessionSummary] = [:]
  private var listRemovals: Set<String> = []
  private var historyAnchors: [String: String] = [:]
  private var initializedHistory: Set<String> = []
  private var activePaginationIDs: Set<String> = []
  private var reconnectHistoryIDs: [String: Set<String>] = [:]
  private var liveLifecycle = UUID()
  private var isForeground = true
  private var hasStarted = false
  private var connectionAttempt = UUID()
  private var listRequest = UUID()
  private var historyRequests: [String: UUID] = [:]
  private var nextSessionsCursor: String?
  private var activeSessionID: String?

  init() {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[
      0]
    let isTesting = ProcessInfo.processInfo.arguments.contains("--ui-testing")
    let isEventGallery =
      isTesting && ProcessInfo.processInfo.arguments.contains("--ui-test-event-gallery")
    let fixtures = isEventGallery ? EventGalleryFixtures.snapshots : DemoFixtures.snapshots
    let store = LocalWorkspaceStore(
      url: support.appendingPathComponent("OmnigentNativeLab")
        .appendingPathComponent(
          isEventGallery
            ? "event-gallery-v1.json" : (isTesting ? "ui-tests-v1.json" : "workspace-v1.json"))
    )
    do {
      let restored: LocalWorkspace?
      if isTesting && ProcessInfo.processInfo.arguments.contains("--reset-demo") {
        restored = nil
        try store.save(LocalWorkspace(snapshots: fixtures))
      } else {
        restored = try store.load()
      }
      self.store = store
      let demo = DemoSessionClient(initialSnapshots: restored?.snapshots ?? fixtures)
      demoClient = demo
      client = demo
      drafts = restored?.drafts ?? [:]
      for snapshot in restored?.snapshots ?? fixtures {
        conversations[snapshot.id] = ConversationState(snapshot: snapshot)
      }
    } catch {
      self.store = nil
      let demo = DemoSessionClient()
      demoClient = demo
      client = demo
      storageError =
        "Saved preview data could not be opened. The file is untouched; this workspace is temporary."
    }
    attachmentObservation = attachmentDrafts.objectWillChange.sink { [weak self] _ in
      self?.objectWillChange.send()
    }
  }

  deinit {
    updatesTask?.cancel()
    activityTask?.cancel()
    inventoryTask?.cancel()
    saveTask?.cancel()
  }

  var sessions: [SessionSummary] {
    let summaries =
      isLive ? Array(liveSummaries.values) : conversations.values.map(\.snapshot.session)
    return summaries.sorted {
      $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt
    }
  }

  var attentionSessions: [SessionSummary] {
    inboxSessions
  }

  var inboxSessions: [SessionSummary] {
    let all = isLive ? Array(liveInventory.values) : sessions
    return all.filter {
      !$0.isArchived
        && ($0.status == .needsResponse
          || !(snapshot(for: $0.id)?.pendingDecisions.isEmpty ?? true))
    }.sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }
  }

  var canCreateSessions: Bool { !isConnecting }

  var newSessionUnavailableReason: String? {
    isConnecting ? "Wait for the server connection to finish." : nil
  }

  var creationNeedsReview: Bool { isLive && uncertainCreationScopes.contains(liveDraftKey) }

  func acknowledgeCreationReview() { uncertainCreationScopes.remove(liveDraftKey) }

  func attachmentKey(for sessionID: String) -> AttachmentDraftKey {
    AttachmentDraftKey(scope: isLive ? liveDraftKey : "demo", sessionID: sessionID)
  }

  var attachmentClient: LocalServerSessionClient? { isLive ? liveClient : nil }

  var notificationScope: NotificationScope? {
    isLive ? NotificationScope(serverURL: connectedServerURL, userID: serverIdentity) : nil
  }

  var notificationSessions: [SessionSummary] {
    guard isLive else { return [] }
    var candidates = liveInventory
    for session in sessions { candidates[session.id] = session }
    return candidates.values.filter { !$0.isArchived && $0.permissionLevel == 4 }
      .sorted { $0.updatedAt > $1.updatedAt }
  }

  func hasAttachments(in sessionID: String) -> Bool {
    attachmentDrafts.draft(for: attachmentKey(for: sessionID)).hasAttachments
  }

  func streamStatus(for sessionID: String) -> String? {
    isLive ? streamStatuses[sessionID] : nil
  }

  func snapshot(for sessionID: String) -> ConversationSnapshot? {
    conversations[sessionID]?.snapshot
  }

  func canPreviewAttachment(_ attachment: ConversationAttachment, sessionID: String) -> Bool {
    if isGalleryAttachment(attachment, sessionID: sessionID) { return true }
    return isLive
      && liveClient?.attachmentFileID(reference: attachment.reference, sessionID: sessionID) != nil
  }

  func loadAttachmentPreview(_ attachment: ConversationAttachment, sessionID: String) async throws
    -> URL
  {
    if isGalleryAttachment(attachment, sessionID: sessionID) {
      return try saveAttachmentPreview(
        Data("Native attachment preview fixture. No server request was made.".utf8),
        fileExtension: "txt")
    }
    guard isLive, let liveClient,
      let fileID = liveClient.attachmentFileID(
        reference: attachment.reference, sessionID: sessionID)
    else { throw AttachmentPreviewError.unsupportedReference }
    let generation = connectionGeneration
    let content = try await liveClient.attachmentContent(sessionID: sessionID, fileID: fileID)
    guard generation == connectionGeneration, isLive else { throw CancellationError() }
    return try saveAttachmentPreview(content.data, fileExtension: content.fileExtension)
  }

  private func isGalleryAttachment(_ attachment: ConversationAttachment, sessionID: String) -> Bool
  {
    let args = ProcessInfo.processInfo.arguments
    return args.contains("--ui-testing") && args.contains("--ui-test-event-gallery")
      && sessionID == "gallery-attachments" && attachment.reference == "file-gallery-contract"
      && !isLive
  }

  private func saveAttachmentPreview(_ data: Data, fileExtension: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "OmnigentAttachmentPreviews", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(
      fileExtension)
    try data.write(to: file, options: [.atomic, .completeFileProtection])
    return file
  }

  func start() async {
    guard !hasStarted else { return }
    hasStarted = true
    if !isLive { await observeDemoUpdates() }
    await refresh()
  }

  @discardableResult
  func connectToLocalServer(bearerToken: String? = nil, expectedUserID: String? = nil) async -> Bool
  {
    let attempt = UUID()
    connectionAttempt = attempt
    isConnecting = true
    connectionError = nil
    defer { if connectionAttempt == attempt { isConnecting = false } }
    do {
      let address = localServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let url = URL(string: address), !address.isEmpty else {
        throw NSError(
          domain: "NativeLab", code: 1,
          userInfo: [
            NSLocalizedDescriptionKey:
              "Enter your server's HTTPS API address, or the local development address."
          ])
      }
      let candidate = try LocalServerSessionClient(
        baseURL: url, bearerToken: bearerToken, expectedUserID: expectedUserID)
      let info = try await candidate.connect()
      guard connectionAttempt == attempt, !Task.isCancelled else {
        await candidate.disconnect()
        return false
      }
      if !isLive {
        flushPersistence()
        demoConversations = conversations
        demoDrafts = drafts
      } else {
        keepLiveDrafts()
      }
      let previousClient = liveClient
      resetConnectionState()
      liveClient = candidate
      client = candidate
      isLive = true
      serverIdentity = info.userID
      connectedServerURL = info.baseURL.absoluteString
      await NativeNotificationController.shared.configure(
        scope: notificationScope, registrationClient: candidate)
      await previousClient?.disconnect()
      guard await connectionIsActive(attempt) else { return false }
      drafts = liveDrafts[liveDraftKey] ?? [:]
      uncertainDeliverySessionIDs = submissionLedger.uncertainSessionIDs(in: liveDraftKey)
      sendingSessionIDs = submissionLedger.pendingSessionIDs(in: liveDraftKey)
      for id in uncertainDeliverySessionIDs {
        errors[id] =
          "A previous send has uncertain delivery. Check the conversation before sending again."
      }
      connectionStatus = "Connecting…"
      hasStarted = true
      await observeLiveUpdates()
      await refresh()
      guard await connectionIsActive(attempt) else { return false }
      await refreshInbox()
      await startLiveSessionList()
      return await connectionIsActive(attempt)
    } catch {
      guard connectionAttempt == attempt, !Task.isCancelled else { return false }
      connectionError = error.localizedDescription
      return false
    }
  }

  private func connectionIsActive(_ attempt: UUID) async -> Bool {
    guard connectionAttempt == attempt else { return false }
    let authenticated = await liveClient?.isConnected == true
    guard connectionAttempt == attempt else { return false }
    if Task.isCancelled {
      await useDemo()
      return false
    }
    if !authenticated {
      await useDemo()
      if !isLive && !isConnecting {
        connectionError = LocalServerClientError.unauthorized.localizedDescription
      }
      return false
    }
    return isLive
  }

  func useDemo() async {
    connectionAttempt = UUID()
    isConnecting = false
    connectionError = nil
    guard isLive else { return }
    keepLiveDrafts()
    let previousClient = liveClient
    resetConnectionState()
    liveClient = nil
    client = demoClient
    isLive = false
    serverIdentity = ""
    connectedServerURL = ""
    let generation = connectionGeneration
    await NativeNotificationController.shared.configure(scope: nil)
    await previousClient?.disconnect()
    guard generation == connectionGeneration, !isLive else { return }
    connectionStatus = "Offline sample workspace"
    conversations = demoConversations
    drafts = demoDrafts
    await observeDemoUpdates()
    await refresh()
  }

  func foregroundRefresh() async {
    let wasSuspended = !isForeground
    isForeground = true
    NativeNotificationController.shared.setForeground(true, activeSessionID: activeSessionID)
    guard hasStarted, isLive, wasSuspended else { return }
    let generation = connectionGeneration
    let lifecycle = UUID()
    liveLifecycle = lifecycle
    if let activeSessionID { streamStatuses[activeSessionID] = "Reconnecting…" }
    await startLiveSessionList()
    guard generation == connectionGeneration, liveLifecycle == lifecycle, isForeground else {
      return
    }
    if let activeSessionID { await loadConversation(activeSessionID) }
    guard generation == connectionGeneration, liveLifecycle == lifecycle, isForeground else {
      return
    }
    await refresh()
    guard generation == connectionGeneration, liveLifecycle == lifecycle, isForeground else {
      return
    }
    await refreshInbox()
  }

  func suspendLiveConnection() async {
    isForeground = false
    NativeNotificationController.shared.setForeground(false, activeSessionID: activeSessionID)
    let lifecycle = UUID()
    liveLifecycle = lifecycle
    inventoryTask?.cancel()
    guard isLive, let liveClient else { return }
    readySessionIDs = []
    if let activeSessionID { streamStatuses[activeSessionID] = "Paused in background" }
    connectionStatus = "Paused in background"
    await liveClient.stopWatching()
    guard liveLifecycle == lifecycle, !isForeground else { return }
    await liveClient.stopSessionListUpdates()
  }

  func refresh() async {
    guard !isRefreshing else { return }
    let generation = connectionGeneration
    let request = UUID()
    listRequest = request
    isRefreshing = true
    isLoadingMoreSessions = false
    listError = nil
    listChanges = [:]
    listRemovals = []
    defer {
      if connectionGeneration == generation, listRequest == request { isRefreshing = false }
    }
    do {
      if let liveClient, isLive {
        let page = try await liveClient.sessionPage(limit: sessionPageSize)
        guard !Task.isCancelled, connectionGeneration == generation, listRequest == request else {
          return
        }
        liveSummaries = Dictionary(
          page.sessions.map { ($0.id, preservingNewerMetadata($0)) },
          uniquingKeysWith: { _, latest in latest })
        for (id, summary) in listChanges where liveSummaries[id] != nil {
          liveSummaries[id] = preservingNewerMetadata(summary)
        }
        for id in listRemovals { liveSummaries[id] = nil }
        nextSessionsCursor = page.nextCursor
        hasMoreSessions = page.nextCursor != nil
        await updateWatchedSessions()
      } else {
        let requestClient = client
        let summaries = try await requestClient.sessions()
        guard !Task.isCancelled, connectionGeneration == generation else { return }
        for summary in summaries {
          do {
            let snapshot = try await requestClient.conversation(id: summary.id)
            guard !Task.isCancelled, connectionGeneration == generation else { return }
            apply(snapshot)
          } catch {
            guard !Task.isCancelled, !(error is CancellationError),
              connectionGeneration == generation
            else { return }
            errors[summary.id] = error.localizedDescription
            listError = "Some conversations could not be refreshed. Pull down to try again."
          }
        }
      }
    } catch {
      guard !Task.isCancelled, !(error is CancellationError), connectionGeneration == generation,
        listRequest == request
      else { return }
      listError = error.localizedDescription
    }
  }

  func loadMoreSessions() async {
    guard isLive, let liveClient, let cursor = nextSessionsCursor,
      !isRefreshing, !isLoadingMoreSessions
    else { return }
    let generation = connectionGeneration
    let request = UUID()
    listRequest = request
    isLoadingMoreSessions = true
    listError = nil
    listChanges = [:]
    listRemovals = []
    defer {
      if connectionGeneration == generation, listRequest == request {
        isLoadingMoreSessions = false
      }
    }
    do {
      let page = try await liveClient.sessionPage(after: cursor, limit: sessionPageSize)
      guard !Task.isCancelled, connectionGeneration == generation, listRequest == request else {
        return
      }
      for summary in page.sessions where !listRemovals.contains(summary.id) {
        liveSummaries[summary.id] = preservingNewerMetadata(listChanges[summary.id] ?? summary)
      }
      nextSessionsCursor = page.nextCursor
      hasMoreSessions = page.nextCursor != nil
      await updateWatchedSessions()
    } catch {
      guard !Task.isCancelled, !(error is CancellationError), connectionGeneration == generation,
        listRequest == request
      else { return }
      listError = error.localizedDescription
    }
  }

  func loadConversation(_ sessionID: String) async {
    if isLive, let liveClient {
      if activeSessionID == sessionID, readySessionIDs.contains(sessionID) { return }
      let generation = connectionGeneration
      activeSessionID = sessionID
      NativeNotificationController.shared.setForeground(isForeground, activeSessionID: sessionID)
      guard isForeground else { return }
      readySessionIDs.remove(sessionID)
      streamStatuses[sessionID] = "Connecting…"
      loadingHistoryIDs.insert(sessionID)
      if !uncertainDeliverySessionIDs.contains(sessionID) { errors[sessionID] = nil }
      do {
        try await liveClient.startWatching(sessionID: sessionID)
      } catch {
        guard generation == connectionGeneration, !Task.isCancelled else { return }
        loadingHistoryIDs.remove(sessionID)
        errors[sessionID] = error.localizedDescription
      }
      return
    }
    let generation = connectionGeneration
    let request = UUID()
    historyRequests[sessionID] = request
    activeSessionID = sessionID
    loadingHistoryIDs.insert(sessionID)
    errors[sessionID] = nil
    defer {
      if connectionGeneration == generation, historyRequests[sessionID] == request {
        loadingHistoryIDs.remove(sessionID)
      }
    }
    do {
      let snapshot = try await client.conversation(id: sessionID)
      guard !Task.isCancelled, connectionGeneration == generation,
        historyRequests[sessionID] == request
      else {
        return
      }
      apply(snapshot)
    } catch {
      guard !Task.isCancelled, !(error is CancellationError), connectionGeneration == generation,
        historyRequests[sessionID] == request
      else {
        return
      }
      errors[sessionID] = error.localizedDescription
    }
  }

  func refreshConversation(_ sessionID: String) async { await loadConversation(sessionID) }

  func closeConversation(_ sessionID: String) {
    guard isLive, activeSessionID == sessionID else { return }
    activeSessionID = nil
    NativeNotificationController.shared.setForeground(isForeground, activeSessionID: nil)
    readySessionIDs.remove(sessionID)
    if let liveClient {
      let generation = connectionGeneration
      Task { @MainActor [weak self] in
        guard let self, self.activeSessionID == nil, self.connectionGeneration == generation else {
          return
        }
        await liveClient.stopWatching()
      }
    }
  }

  func refreshInbox() async {
    guard isLive, let liveClient, !isLoadingInbox else { return }
    let generation = connectionGeneration
    isLoadingInbox = true
    inboxError = nil
    inventoryChanges = [:]
    inventoryRemovals = []
    defer { if connectionGeneration == generation { isLoadingInbox = false } }
    do {
      let inventory = try await liveClient.sessionInventory()
      guard generation == connectionGeneration, !Task.isCancelled else { return }
      liveInventory = Dictionary(
        inventory.map { ($0.id, preservingNewerMetadata($0)) },
        uniquingKeysWith: { _, new in new })
      for (id, summary) in inventoryChanges {
        liveInventory[id] = preservingNewerMetadata(summary)
      }
      for id in inventoryRemovals { liveInventory[id] = nil }
      for id in Array(liveSummaries.keys) {
        liveSummaries[id] = liveInventory[id]
      }
      await updateWatchedSessions()
    } catch {
      guard generation == connectionGeneration, !Task.isCancelled else { return }
      inboxError = "Inbox could not be updated. \(error.localizedDescription)"
    }
  }

  func hasMoreHistory(for sessionID: String) -> Bool { historyCursors[sessionID] != nil }

  func isLoadingHistory(for sessionID: String) -> Bool { loadingHistoryIDs.contains(sessionID) }

  func loadOlderMessages(_ sessionID: String) async {
    guard isLive, let liveClient, let cursor = historyCursors[sessionID],
      !loadingHistoryIDs.contains(sessionID)
    else { return }
    let generation = connectionGeneration
    let request = UUID()
    historyRequests[sessionID] = request
    let anchor = historyAnchors[sessionID]
    activePaginationIDs.insert(sessionID)
    loadingHistoryIDs.insert(sessionID)
    errors[sessionID] = nil
    defer {
      if connectionGeneration == generation, historyRequests[sessionID] == request {
        activePaginationIDs.remove(sessionID)
        loadingHistoryIDs.remove(sessionID)
      }
    }
    do {
      let page = try await liveClient.historyPage(sessionID: sessionID, after: cursor)
      guard !Task.isCancelled, connectionGeneration == generation,
        historyRequests[sessionID] == request,
        historyCursors[sessionID] == cursor,
        var snapshot = snapshot(for: sessionID)
      else { return }
      var seen: Set<String> = []
      let anchorIndex =
        anchor.flatMap { anchor in
          snapshot.messages.firstIndex { $0.id == anchor }
        } ?? 0
      let incomingIDs = Set(page.messages.map(\.id))
      let prefix = snapshot.messages.prefix(anchorIndex).filter { !incomingIDs.contains($0.id) }
      let suffix = snapshot.messages.dropFirst(anchorIndex).filter { !incomingIDs.contains($0.id) }
      snapshot.messages = (prefix + page.messages + suffix).filter { seen.insert($0.id).inserted }
      replaceLiveSnapshot(snapshot)
      historyCursors[sessionID] = page.nextCursor
      if let first = page.messages.first { historyAnchors[sessionID] = first.id }
    } catch {
      guard !Task.isCancelled, !(error is CancellationError), connectionGeneration == generation,
        historyRequests[sessionID] == request
      else {
        return
      }
      errors[sessionID] = error.localizedDescription
    }
  }

  func setDraft(_ text: String, for sessionID: String) {
    drafts[sessionID] = text
    if isLive { keepLiveDrafts() } else { schedulePersistence() }
  }

  func clearError(for sessionID: String) {
    guard !uncertainDeliverySessionIDs.contains(sessionID) else { return }
    errors[sessionID] = nil
  }

  func composerUnavailableReason(for sessionID: String) -> String? {
    if configurationOperations.contains(configurationKey(sessionID)) {
      return "Applying session settings…"
    }
    if configurationNeedsReview(sessionID) {
      return "Review uncertain settings in Harness & model before sending."
    }
    guard let snapshot = snapshot(for: sessionID) else { return "Loading this conversation…" }
    if snapshot.session.isReadOnly { return "You have read-only access to this conversation." }
    if snapshot.session.isArchived {
      return "Restore this session from the menu before sending a message."
    }
    if uncertainDeliverySessionIDs.contains(sessionID) {
      return "Delivery is uncertain. Check the conversation before sending again."
    }
    if isLive && !readySessionIDs.contains(sessionID) {
      return "Connecting to this conversation… Your draft is kept."
    }
    if isLive, let reason = snapshot.session.configuration?.executionUnavailableReason {
      return reason
    }
    if !snapshot.pendingDecisions.isEmpty || snapshot.session.status == .needsResponse {
      return "Respond to the request above before sending a message."
    }
    if snapshot.session.status == .running {
      return "A reply is arriving. Wait for it to finish or tap Stop."
    }
    if sendingSessionIDs.contains(sessionID) { return "Sending your message…" }
    if isLive && !attachmentDrafts.canSubmit(in: attachmentKey(for: sessionID)) {
      return "Wait for attachments to upload, or review and remove an unsuccessful upload."
    }
    return nil
  }

  private func configurationKey(_ id: String) -> String {
    "\(isLive ? liveDraftKey : "demo")|\(id)"
  }

  func configurationNeedsReview(_ id: String) -> Bool {
    uncertainConfigurationOperations.contains(configurationKey(id))
  }

  func configurationUnavailableReason(_ id: String) -> String? {
    guard let session = snapshot(for: id)?.session else { return "Loading session settings…" }
    if session.isReadOnly {
      return "You have read-only access. Settings can be inspected but not changed."
    }
    if session.isArchived { return "Restore this session before changing settings." }
    if session.status != .idle {
      return "Available when this response or pending request finishes."
    }
    if sendingSessionIDs.contains(id) || configurationOperations.contains(configurationKey(id)) {
      return "Wait for the current action to finish."
    }
    if uncertainDeliverySessionIDs.contains(id) {
      return "Review the uncertain message delivery before changing settings."
    }
    if configurationNeedsReview(id) {
      return
        "The last settings change has uncertain delivery. Review current settings before continuing."
    }
    if isLive && !readySessionIDs.contains(id) {
      return "Reconnect to this conversation before changing settings."
    }
    if isLive, let config = session.configuration,
      config.hostOnline != true && config.runnerOnline != true
    {
      return "Reconnect the session's host before changing settings."
    }
    return nil
  }

  func loadConfigurationCatalog(_ id: String) async throws -> ConfigurationCatalog {
    let generation = connectionGeneration
    let catalog: ConfigurationCatalog
    if let liveClient, isLive {
      catalog = try await liveClient.configurationCatalog(sessionID: id)
    } else {
      catalog = .demo
    }
    guard generation == connectionGeneration else { throw CancellationError() }
    return catalog
  }

  func reviewConfiguration(_ id: String) async throws {
    let generation = connectionGeneration
    let key = configurationKey(id)
    guard !configurationOperations.contains(key) else { throw SessionClientError.busy }
    if let liveClient, isLive {
      let summary = try await liveClient.configurationSnapshot(id)
      guard generation == connectionGeneration else { throw CancellationError() }
      if var snapshot = snapshot(for: id) {
        snapshot.session = summary
        replaceLiveSnapshot(snapshot)
      }
    }
    uncertainConfigurationOperations.remove(key)
  }

  func applyConfiguration(_ edit: ConfigurationEdit, to id: String, target: HarnessChoice? = nil)
    async throws
  {
    if let reason = configurationUnavailableReason(id) {
      throw ConfigurationError.unavailable(reason)
    }
    let generation = connectionGeneration
    let key = configurationKey(id)
    configurationOperations.insert(key)
    defer { configurationOperations.remove(key) }
    do {
      if let liveClient, isLive {
        let summary: SessionSummary
        if let target {
          summary = try await liveClient.switchHarness(
            to: target.id, baseline: edit.baseline, sessionID: id)
        } else {
          summary = try await liveClient.applyConfiguration(edit, sessionID: id)
        }
        guard generation == connectionGeneration else {
          uncertainConfigurationOperations.insert(key)
          throw CancellationError()
        }
        if var snapshot = snapshot(for: id) {
          snapshot.session = summary
          replaceLiveSnapshot(snapshot)
        }
      } else {
        let updated = try await demoClient.configure(sessionID: id, edit: edit, target: target)
        guard generation == connectionGeneration else { throw CancellationError() }
        apply(updated)
      }
    } catch {
      if error as? LocalServerClientError == .deliveryUncertain {
        uncertainConfigurationOperations.insert(key)
      }
      if generation == connectionGeneration, let liveClient, isLive,
        let summary = try? await liveClient.configurationSnapshot(id),
        generation == connectionGeneration, var snapshot = snapshot(for: id)
      {
        snapshot.session = summary
        replaceLiveSnapshot(snapshot)
      }
      throw error
    }
  }

  func sendMessage(in sessionID: String) async {
    guard composerUnavailableReason(for: sessionID) == nil else { return }
    let draft = drafts[sessionID] ?? ""
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty || (isLive && hasAttachments(in: sessionID)) else { return }
    if let liveClient, isLive {
      await submitLiveMessage(text, draft: draft, sessionID: sessionID, using: liveClient)
      return
    }
    let generation = connectionGeneration
    sendingSessionIDs.insert(sessionID)
    errors[sessionID] = nil
    defer { if connectionGeneration == generation { sendingSessionIDs.remove(sessionID) } }
    do {
      try await client.send(text, to: sessionID)
      guard connectionGeneration == generation else { return }
      if drafts[sessionID] == draft { drafts[sessionID] = "" }
      await loadConversation(sessionID)
      guard connectionGeneration == generation else { return }
      flushPersistence()
    } catch {
      guard connectionGeneration == generation else { return }
      errors[sessionID] = error.localizedDescription
    }
  }

  private func submitLiveMessage(
    _ text: String, draft: String, sessionID: String, using liveClient: LocalServerSessionClient
  ) async {
    let attachmentKey = attachmentKey(for: sessionID)
    guard attachmentDrafts.canSubmit(in: attachmentKey) else { return }
    guard
      let operation = submissionLedger.begin(
        scope: liveDraftKey, sessionID: sessionID, draft: draft)
    else { return }
    // Capture this exact batch before the first suspension; later additions stay in the draft.
    let batch: AttachmentSubmission
    do {
      batch = try attachmentDrafts.beginSubmission(in: attachmentKey)
    } catch {
      finishLiveSubmission(operation, outcome: .rejected, error: error.localizedDescription)
      return
    }
    sendingSessionIDs = submissionLedger.pendingSessionIDs(in: liveDraftKey)
    errors[sessionID] = nil
    do {
      let result = try await liveClient.submitMessage(
        text, attachments: batch.attachments, to: sessionID)
      attachmentDrafts.finishSubmission(batch, outcome: result.denied ? .rejected : .accepted)
      finishLiveSubmission(
        operation, outcome: result.denied ? .rejected : .accepted, result: result,
        error: result.denied
          ? "The server did not accept this message. Your draft is unchanged." : nil
      )
    } catch {
      attachmentDrafts.finishSubmission(
        batch,
        outcome: error as? LocalServerClientError == .deliveryUncertain ? .uncertain : .rejected)
      finishLiveSubmission(
        operation,
        outcome: error as? LocalServerClientError == .deliveryUncertain ? .uncertain : .rejected,
        error: error.localizedDescription
      )
    }
  }

  private func finishLiveSubmission(
    _ operation: SubmissionLedger.Operation, outcome: SubmissionLedger.Outcome,
    result: MessageSubmission? = nil, error: String? = nil
  ) {
    let isCurrentScope = isLive && liveDraftKey == operation.scope
    let currentDraft =
      isCurrentScope
      ? (drafts[operation.sessionID] ?? "")
      : (liveDrafts[operation.scope]?[operation.sessionID] ?? "")
    guard
      let resolution = submissionLedger.complete(
        operation, outcome: outcome, currentDraft: currentDraft)
    else { return }
    liveDrafts[operation.scope, default: [:]][operation.sessionID] = resolution.draft
    // A reconnection can replace the view generation while this exact send remains in flight.
    guard isCurrentScope else { return }
    drafts[operation.sessionID] = resolution.draft
    sendingSessionIDs = submissionLedger.pendingSessionIDs(in: operation.scope)
    uncertainDeliverySessionIDs = submissionLedger.uncertainSessionIDs(in: operation.scope)
    if let error { errors[operation.sessionID] = error }
    if resolution.isUncertain {
      deliveryNotices[operation.sessionID] = "Delivery unknown · Draft kept"
    } else if let result, !result.denied {
      pendingSubmissions[operation.sessionID] = result
      let consumed =
        result.itemID.map { consumedItemIDs[operation.sessionID]?.contains($0) == true } == true
        || result.pendingID.map { consumedPendingIDs[operation.sessionID]?.contains($0) == true }
          == true
      deliveryNotices[operation.sessionID] =
        consumed
        ? "Recorded in conversation"
        : (result.queued ? "Queued — waiting for the agent" : "Accepted by server")
    }
  }

  func allowRetryAfterReview(in sessionID: String) {
    attachmentDrafts.acknowledgeUncertainty(in: attachmentKey(for: sessionID))
    if isLive { submissionLedger.acknowledgeUncertainty(scope: liveDraftKey, sessionID: sessionID) }
    uncertainDeliverySessionIDs.remove(sessionID)
    errors[sessionID] = nil
    deliveryNotices[sessionID] = nil
    if isLive { keepLiveDrafts() }
  }

  func stopResponse(in sessionID: String) async {
    guard let session = snapshot(for: sessionID)?.session, !session.isReadOnly,
      !stoppingSessionIDs.contains(sessionID)
    else { return }
    let generation = connectionGeneration
    stoppingSessionIDs.insert(sessionID)
    errors[sessionID] = nil
    defer { if connectionGeneration == generation { stoppingSessionIDs.remove(sessionID) } }
    do {
      try await client.interrupt(sessionID: sessionID)
      guard connectionGeneration == generation else { return }
      if !isLive { await loadConversation(sessionID) }
    } catch {
      guard connectionGeneration == generation else { return }
      errors[sessionID] = error.localizedDescription
    }
  }

  func isResolving(_ decision: DecisionRequest) -> Bool {
    resolvingDecisionIDs.contains(decisionKey(decision))
  }

  func resolve(
    _ decision: DecisionRequest, response: DecisionResponse, displayedIn sessionID: String
  ) async {
    let key = decisionKey(decision)
    guard snapshot(for: sessionID)?.session.isReadOnly == false,
      decision.unsupportedReason == nil, decision.response == nil,
      !resolvingDecisionIDs.contains(key)
    else { return }
    let generation = connectionGeneration
    resolvingDecisionIDs.insert(key)
    errors[sessionID] = nil
    defer { if connectionGeneration == generation { resolvingDecisionIDs.remove(key) } }
    do {
      try await client.resolve(
        decisionID: decision.id, sessionID: decision.targetSessionID, response: response)
      guard connectionGeneration == generation else { return }
      if !isLive { await loadConversation(sessionID) }
      if !isLive, connectionGeneration == generation, decision.targetSessionID != sessionID {
        await loadConversation(decision.targetSessionID)
      }
      if isLive { await refreshInbox() }
    } catch {
      guard connectionGeneration == generation else { return }
      errors[sessionID] = error.localizedDescription
    }
  }

  func createConversation(title: String, prompt: String) async throws -> String {
    guard canCreateSessions else {
      throw NSError(
        domain: "NativeLab", code: 2,
        userInfo: [
          NSLocalizedDescriptionKey: newSessionUnavailableReason
            ?? "Session creation is unavailable."
        ])
    }
    let generation = connectionGeneration
    let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { throw SessionClientError.emptyMessage }
    let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let fallbackName = String(text.prefix(40)).replacingOccurrences(of: "\n", with: " ")
    let snapshot = try await client.createSession(title: name.isEmpty ? fallbackName : name)
    guard connectionGeneration == generation else { throw CancellationError() }
    apply(snapshot)
    drafts[snapshot.id] = text
    await sendMessage(in: snapshot.id)
    guard connectionGeneration == generation else { throw CancellationError() }
    return snapshot.id
  }

  func loadSessionCreationCatalog() async throws -> SessionCreationCatalog {
    let generation = connectionGeneration
    guard isLive, let liveClient else {
      throw SessionCreationError.unavailable("Connect to a server first.")
    }
    let catalog = try await liveClient.sessionCreationCatalog()
    guard generation == connectionGeneration else { throw CancellationError() }
    return catalog
  }

  func loadCreationWorkspaces(hostID: String) async throws -> [CreationWorkspace] {
    let generation = connectionGeneration
    guard isLive, let liveClient else { throw CancellationError() }
    let workspaces = try await liveClient.creationWorkspaces(hostID: hostID)
    guard generation == connectionGeneration else { throw CancellationError() }
    return workspaces
  }

  func loadCreationModels(agentID: String, hostID: String) async throws -> [ModelChoice] {
    let generation = connectionGeneration
    guard isLive, let liveClient else { throw CancellationError() }
    let models = try await liveClient.creationModels(agentID: agentID, hostID: hostID)
    guard generation == connectionGeneration else { throw CancellationError() }
    return models
  }

  func createLiveConversation(selection: SessionCreationSelection, title: String, prompt: String)
    async throws -> String
  {
    guard isLive, let liveClient else {
      throw SessionCreationError.unavailable("Connect to a server first.")
    }
    let scope = liveDraftKey
    guard !uncertainCreationScopes.contains(scope) else { throw SessionCreationError.uncertain }
    guard creatingScopes.insert(scope).inserted else { throw SessionClientError.busy }
    defer { creatingScopes.remove(scope) }
    let generation = connectionGeneration
    let receipt: SessionCreationReceipt
    do {
      receipt = try await liveClient.createSession(selection: selection, title: title)
    } catch {
      if error as? SessionCreationError == .uncertain { uncertainCreationScopes.insert(scope) }
      throw error
    }
    liveDrafts[scope, default: [:]][receipt.sessionID] = prompt
    guard generation == connectionGeneration, isLive, liveDraftKey == scope else {
      // The acknowledged session exists even if the user switched connections while it started.
      throw SessionCreationError.unavailable(
        "The session was created. Reconnect to its server and open Sessions to continue it.")
    }
    if let summary = receipt.summary {
      liveSummaries[summary.id] = summary
      liveInventory[summary.id] = summary
      replaceLiveSnapshot(ConversationSnapshot(revision: 0, session: summary, messages: []))
    }
    drafts[receipt.sessionID] = prompt
    if !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      deliveryNotices[receipt.sessionID] = "Session created · Review and send your first message"
    }
    // Navigation opens the stream. Creation acknowledgement never depends on first-message delivery.
    return receipt.sessionID
  }

  func editSession(_ sessionID: String, change: SessionChange) async {
    guard !editingSessionIDs.contains(sessionID),
      let session = snapshot(for: sessionID)?.session ?? liveSummaries[sessionID]
        ?? liveInventory[sessionID]
    else { return }
    switch change {
    case .title: guard session.canRename else { return }
    case .pinned: guard session.canPin else { return }
    case .archived: guard session.canArchive else { return }
    }
    let generation = connectionGeneration
    editingSessionIDs.insert(sessionID)
    errors[sessionID] = nil
    defer { if connectionGeneration == generation { editingSessionIDs.remove(sessionID) } }
    do {
      try await client.editSession(sessionID, change: change)
      guard connectionGeneration == generation else { return }
      if isLive {
        await refreshInbox()
      } else {
        await loadConversation(sessionID)
      }
      guard connectionGeneration == generation else { return }
      flushPersistence()
    } catch {
      guard connectionGeneration == generation else { return }
      errors[sessionID] = error.localizedDescription
    }
  }

  func flushPersistence() {
    saveTask?.cancel()
    if isLive {
      keepLiveDrafts()
      return
    }
    guard !isLive, let store else { return }
    do {
      try store.save(
        LocalWorkspace(snapshots: conversations.values.map(\.snapshot), drafts: drafts))
      storageError = nil
    } catch {
      storageError =
        "Changes could not be saved on this device. Keep the app open and free some storage."
    }
  }

  private func observeDemoUpdates() async {
    let generation = connectionGeneration
    let updates = await demoClient.updates()
    guard !isLive, connectionGeneration == generation else { return }
    updatesTask?.cancel()
    updatesTask = Task { @MainActor [weak self] in
      for await snapshot in updates {
        guard !Task.isCancelled, let self, self.connectionGeneration == generation, !self.isLive
        else { return }
        self.apply(snapshot)
      }
    }
  }

  private var liveDraftKey: String { "\(connectedServerURL)|\(serverIdentity)" }

  private func keepLiveDrafts() {
    guard isLive else { return }
    liveDrafts[liveDraftKey] = drafts
  }

  private func observeLiveUpdates() async {
    guard let liveClient, isLive else { return }
    let generation = connectionGeneration
    let updates = await liveClient.updates()
    let activity = await liveClient.activityUpdates()
    guard generation == connectionGeneration else { return }
    updatesTask = Task { @MainActor [weak self] in
      for await snapshot in updates {
        guard let self, !Task.isCancelled, self.connectionGeneration == generation else { return }
        self.mergeLiveSnapshot(snapshot)
      }
    }
    activityTask = Task { @MainActor [weak self] in
      for await event in activity {
        guard let self, !Task.isCancelled, self.connectionGeneration == generation else { return }
        self.receive(event)
      }
    }
  }

  private func startLiveSessionList() async {
    guard isLive, isForeground, let liveClient else { return }
    let generation = connectionGeneration
    do {
      try await liveClient.startSessionListUpdates(sessionIDs: watchedSessionIDs)
    } catch {
      guard generation == connectionGeneration, !Task.isCancelled else { return }
      connectionStatus = "Reconnecting…"
      isReconnecting = true
      listError = error.localizedDescription
    }
  }

  private var watchedSessionIDs: [String] {
    Array(Set(liveSummaries.keys).union(liveInventory.keys)).sorted()
  }

  private func updateWatchedSessions() async {
    guard isLive, isForeground, let liveClient else { return }
    let generation = connectionGeneration
    do {
      try await liveClient.setWatchedSessionIDs(watchedSessionIDs)
    } catch {
      guard generation == connectionGeneration, !Task.isCancelled else { return }
      listError = error.localizedDescription
    }
  }

  private func receive(_ event: LocalServerActivity) {
    switch event {
    case .streamState(let sessionID, let state):
      switch state {
      case .connecting:
        readySessionIDs.remove(sessionID)
        streamStatuses[sessionID] = "Connecting…"
        reconnectHistoryIDs[sessionID] = Set(snapshot(for: sessionID)?.messages.map(\.id) ?? [])
      case .live:
        guard isForeground else { return }
        readySessionIDs.insert(sessionID)
        if !activePaginationIDs.contains(sessionID) { loadingHistoryIDs.remove(sessionID) }
        streamStatuses[sessionID] = "Connected"
      case .reconnecting:
        readySessionIDs.remove(sessionID)
        streamStatuses[sessionID] = "Reconnecting…"
        if reconnectHistoryIDs[sessionID] == nil {
          reconnectHistoryIDs[sessionID] = Set(snapshot(for: sessionID)?.messages.map(\.id) ?? [])
        }
      case .stopped:
        readySessionIDs.remove(sessionID)
        loadingHistoryIDs.remove(sessionID)
        streamStatuses[sessionID] = isForeground ? "Disconnected" : "Paused in background"
      case .failed(let message):
        readySessionIDs.remove(sessionID)
        loadingHistoryIDs.remove(sessionID)
        streamStatuses[sessionID] = "Connection interrupted"
        errors[sessionID] = message
      }
    case .listState(let state):
      switch state {
      case .connecting:
        connectionStatus = "Connecting…"
        isReconnecting = false
      case .live:
        guard isForeground else { return }
        connectionStatus = "Connected"
        isReconnecting = false
        listError = nil
      case .reconnecting:
        connectionStatus = "Reconnecting…"
        isReconnecting = true
      case .stopped: connectionStatus = isForeground ? "Disconnected" : "Paused in background"
      case .failed(let message):
        connectionStatus = "Connection interrupted"
        isReconnecting = false
        listError = message
      }
    case .sessionsChanged(let summaries):
      for incoming in summaries {
        let summary = preservingNewerMetadata(incoming)
        if liveSummaries[summary.id] != nil || liveInventory[summary.id] == nil {
          liveSummaries[summary.id] = summary
        }
        liveInventory[summary.id] = summary
        if isRefreshing || isLoadingMoreSessions {
          listChanges[summary.id] = summary
          listRemovals.remove(summary.id)
        }
        if isLoadingInbox {
          inventoryChanges[summary.id] = summary
          inventoryRemovals.remove(summary.id)
        }
        if var snapshot = snapshot(for: summary.id) {
          snapshot.session = summary
          replaceLiveSnapshot(snapshot)
        }
      }
    case .sessionsRemoved(let ids):
      for id in ids {
        liveSummaries[id] = nil
        liveInventory[id] = nil
        if isRefreshing || isLoadingMoreSessions {
          listChanges[id] = nil
          listRemovals.insert(id)
        }
        if isLoadingInbox {
          inventoryChanges[id] = nil
          inventoryRemovals.insert(id)
        }
      }
    case .inventoryInvalidated:
      scheduleInventoryRefresh()
    case .historyCursor(let sessionID, let cursor, let firstMessageID):
      let priorIDs = reconnectHistoryIDs.removeValue(forKey: sessionID)
      let overlaps = firstMessageID.map { priorIDs?.contains($0) == true } == true
      // Keep the oldest loaded cursor unless reconnection introduces a history gap.
      if !initializedHistory.contains(sessionID) || (priorIDs != nil && !overlaps) {
        historyCursors[sessionID] = cursor
        historyAnchors[sessionID] = firstMessageID
      }
      initializedHistory.insert(sessionID)
    case .inputConsumed(let sessionID, let itemID, let pendingID):
      consumedItemIDs[sessionID, default: []].insert(itemID)
      if let pendingID { consumedPendingIDs[sessionID, default: []].insert(pendingID) }
      if let submission = pendingSubmissions[sessionID],
        submission.itemID == itemID || (pendingID != nil && submission.pendingID == pendingID)
      {
        pendingSubmissions[sessionID] = nil
        deliveryNotices[sessionID] = "Recorded in conversation"
      }
    case .error(let message):
      listError = message
    case .conversationError(let sessionID, let message):
      errors[sessionID] = message
    }
  }

  private func scheduleInventoryRefresh() {
    guard isForeground else { return }
    inventoryTask?.cancel()
    let generation = connectionGeneration
    inventoryTask = Task { @MainActor [weak self] in
      do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
      guard let self, self.connectionGeneration == generation, self.isForeground else { return }
      await self.refreshInbox()
    }
  }

  private func mergeLiveSnapshot(_ incoming: ConversationSnapshot) {
    var snapshot = incoming
    snapshot.session = preservingNewerMetadata(snapshot.session)
    let incomingByID = Dictionary(
      incoming.messages.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
    let previous = conversations[incoming.id]?.snapshot.messages ?? []
    var seen = Set<String>()
    var messages = previous.compactMap { old -> ConversationMessage? in
      if let current = incomingByID[old.id] { return current }
      return old.isStreaming || old.id.hasPrefix("live:") ? nil : old
    }.filter { seen.insert($0.id).inserted }
    messages.append(contentsOf: incoming.messages.filter { seen.insert($0.id).inserted })
    snapshot.messages = messages
    replaceLiveSnapshot(snapshot)
    liveInventory[snapshot.id] = snapshot.session
    liveSummaries[snapshot.id] = snapshot.session
    if isRefreshing || isLoadingMoreSessions { listChanges[snapshot.id] = snapshot.session }
    if isLoadingInbox { inventoryChanges[snapshot.id] = snapshot.session }
    if !activePaginationIDs.contains(snapshot.id) { loadingHistoryIDs.remove(snapshot.id) }
  }

  private func resetConnectionState() {
    if let liveClient {
      Task {
        await liveClient.stopWatching()
        await liveClient.stopSessionListUpdates()
      }
    }
    updatesTask?.cancel()
    activityTask?.cancel()
    inventoryTask?.cancel()
    saveTask?.cancel()
    connectionGeneration = UUID()
    listRequest = UUID()
    conversations = [:]
    drafts = [:]
    liveSummaries = [:]
    liveInventory = [:]
    readySessionIDs = []
    streamStatuses = [:]
    isLoadingInbox = false
    inboxError = nil
    isReconnecting = false
    deliveryNotices = [:]
    uncertainDeliverySessionIDs = []
    pendingSubmissions = [:]
    consumedItemIDs = [:]
    consumedPendingIDs = [:]
    historyAnchors = [:]
    initializedHistory = []
    activePaginationIDs = []
    reconnectHistoryIDs = [:]
    errors = [:]
    listError = nil
    activeSessionID = nil
    historyRequests = [:]
    historyCursors = [:]
    loadingHistoryIDs = []
    nextSessionsCursor = nil
    hasMoreSessions = false
    isRefreshing = false
    isLoadingMoreSessions = false
    sendingSessionIDs = []
    stoppingSessionIDs = []
    resolvingDecisionIDs = []
    editingSessionIDs = []
  }

  private func replaceLiveSnapshot(_ incoming: ConversationSnapshot) {
    var snapshot = incoming
    snapshot.session = preservingNewerMetadata(snapshot.session)
    if let previousFailure = conversations[incoming.id]?.snapshot.session.failureMessage,
      incoming.session.failureMessage == nil, errors[incoming.id] == previousFailure
    {
      errors[incoming.id] = nil
    }
    snapshot.revision = (conversations[incoming.id]?.snapshot.revision ?? 0) + 1
    conversations[snapshot.id] = ConversationState(snapshot: snapshot)
    if liveSummaries[snapshot.id] != nil { liveSummaries[snapshot.id] = snapshot.session }
  }

  private func preservingNewerMetadata(_ summary: SessionSummary) -> SessionSummary {
    summary
      .preservingNewerMetadata(from: liveSummaries[summary.id])
      .preservingNewerMetadata(from: liveInventory[summary.id])
      .preservingNewerMetadata(from: conversations[summary.id]?.snapshot.session)
  }

  private func apply(_ snapshot: ConversationSnapshot) {
    guard !isLive else { return }
    if var state = conversations[snapshot.id] {
      if state.apply(snapshot) { conversations[snapshot.id] = state }
    } else {
      conversations[snapshot.id] = ConversationState(snapshot: snapshot)
    }
    schedulePersistence()
  }

  private func schedulePersistence() {
    guard !isLive else { return }
    let generation = connectionGeneration
    saveTask?.cancel()
    saveTask = Task { @MainActor [weak self] in
      do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
      guard let self, self.connectionGeneration == generation else { return }
      self.flushPersistence()
    }
  }

  private var sessionPageSize: Int {
    let arguments = ProcessInfo.processInfo.arguments
    if arguments.contains("--ui-testing"), let index = arguments.firstIndex(of: "--live-page-size"),
      arguments.indices.contains(index + 1), let size = Int(arguments[index + 1]),
      (1...100).contains(size)
    {
      return size
    }
    return 50
  }

  private func decisionKey(_ decision: DecisionRequest) -> String {
    "\(decision.targetSessionID)/\(decision.id)"
  }
}
