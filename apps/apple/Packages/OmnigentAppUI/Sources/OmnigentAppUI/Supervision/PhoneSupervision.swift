#if os(iOS)
  import BackgroundTasks
  public import Foundation
  public import Observation
  import OSLog
  import OmnigentCoreFFI
  public import OmnigentStores
  import UIKit
  public import UserNotifications

  /// Phone supervision without server push: actionable notifications for what needs the user,
  /// from the core's events while the app runs or was just backgrounded, and from a
  /// `BGAppRefreshTask` poll of attention after that.
  ///
  /// Approve, Deny and Reply re-check the request through the core before answering it
  /// (``SupervisionActionRouter``). Install it from the app delegate's
  /// `application(_:didFinishLaunchingWithOptions:)`, so actions and refresh tasks that launch
  /// the app in the background reach it.
  @Observable
  public final class PhoneSupervision: NSObject {
    /// The `BGTaskSchedulerPermittedIdentifiers` entry.
    public static let refreshTaskIdentifier = "ai.omnigent.attention-refresh"
    /// How long after backgrounding the app keeps its streams to notify from live events.
    static let backgroundGrace: Duration = .seconds(25)
    /// The earliest next background poll.
    static let refreshInterval: TimeInterval = 15 * 60
    static let ledgerKey = "omnigent.supervision.ledger"

    /// Which kinds notify.
    public let preferences: SupervisionPreferences
    /// The notification permission, as last read.
    public private(set) var authorization: UNAuthorizationStatus = .notDetermined
    /// The last failure, for Settings › Notifications.
    public private(set) var lastError: String?
    /// A tapped notification waiting for the scene to open its session.
    public var pendingOpen: SupervisionPayload?
    /// The server the app last used, for a poll with no scene.
    @ObservationIgnored public var lastServerURL: () -> String? = { nil }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let connections: SupervisionConnections
    @ObservationIgnored private var ledger: SupervisionLedger
    /// Connections opened for background work when no scene had one.
    @ObservationIgnored private var headless: [String: ServerSession] = [:]
    @ObservationIgnored private let logger = Logger(
      subsystem: "ai.omnigent.ios", category: "supervision")

    /// Creates the coordinator.
    /// - Parameters:
    ///   - defaults: Where the preferences and the notified-request ledger are kept.
    ///   - connections: The scenes' connections.
    public init(defaults: UserDefaults = .standard, connections: SupervisionConnections = .shared) {
      self.defaults = defaults
      self.connections = connections
      preferences = SupervisionPreferences(defaults: defaults)
      ledger = SupervisionLedger(entries: defaults.stringArray(forKey: Self.ledgerKey) ?? [])
      super.init()
    }

    /// Becomes the notification delegate, registers the categories and the refresh task.
    public func install() {
      let center = UNUserNotificationCenter.current()
      center.delegate = self
      center.setNotificationCategories(SupervisionNotificationCategories.all)
      let registered = BGTaskScheduler.shared.register(
        forTaskWithIdentifier: Self.refreshTaskIdentifier, using: .main
      ) { [weak self] task in
        MainActor.assumeIsolated { self?.run(task) }
      }
      if !registered {
        report("The background refresh task is not permitted by Info.plist.")
      }
      Task { await refreshAuthorization() }
    }

    /// Re-reads the permission.
    public func refreshAuthorization() async {
      // The completion form: only the Sendable status crosses back to the main actor.
      authorization = await withCheckedContinuation { continuation in
        UNUserNotificationCenter.current().getNotificationSettings { settings in
          continuation.resume(returning: settings.authorizationStatus)
        }
      }
      logger.notice("Notification permission: \(self.authorization.rawValue, privacy: .public)")
    }

    /// A scene signed in: actions may use its connection, the core may notify, and permission
    /// is asked for the first time.
    /// - Parameter connection: The scene's signed-in connection.
    public func didSignIn(_ connection: ConnectionStore) async {
      connections.register(connection)
      logger.notice("Supervising a signed-in connection")
      // The system prompts only while undecided; afterwards this returns the decision.
      await requestAuthorization()
      connection.notifications?.setAllowed(isAllowed)
    }

    /// Asks for alert, sound and badge permission.
    public func requestAuthorization() async {
      do {
        let granted = try await UNUserNotificationCenter.current().requestAuthorization(
          options: [.alert, .sound, .badge])
        logger.notice("Notification permission granted: \(granted, privacy: .public)")
      } catch {
        report("Notification permission could not be requested: \(error.localizedDescription)")
      }
      await refreshAuthorization()
    }

    /// Whether notifications may be shown.
    public var isAllowed: Bool {
      authorization == .authorized || authorization == .provisional
        || authorization == .ephemeral
    }

    // MARK: - Delivery

    /// Posts what the core decided to notify for `connection`: each request a session now
    /// waits on (re-read through the core), and turn ends.
    /// - Parameter connection: A signed-in connection.
    public func deliverPending(from connection: ConnectionStore) async {
      guard let notifications = connection.notifications, isAllowed,
        let server = connection.supervisedServerURL
      else { return }
      for notification in notifications.take() {
        switch notification.kind {
        case .approval:
          await notifyDecisions(
            in: [notification.sessionId], connection: connection)
        case .completed, .failed:
          let kind: SupervisionKind = notification.kind == .failed ? .failed : .completed
          guard preferences.isEnabled(kind) else { continue }
          await post(
            .turnEnded(
              kind, serverURL: server, sessionID: notification.sessionId,
              sessionTitle: notification.title
                ?? connection.sessionList.session(notification.sessionId)?.title))
        }
      }
    }

    /// Notifies every request the connection's sessions wait on and that was not notified yet:
    /// the poll, run on backgrounding and from the refresh task.
    /// - Parameter connection: A signed-in connection.
    public func sweep(_ connection: ConnectionStore) async {
      guard isAllowed else { return }
      let list = connection.sessionList
      // A sub-agent's requests are read through its parent, which mirrors them.
      let sessions = list.needsResponse.filter { !$0.isArchived }.map {
        list.parent(of: $0.id) ?? $0.id
      }
      logger.notice("Sweeping \(sessions.count, privacy: .public) sessions that need you")
      var seen: Set<String> = []
      await notifyDecisions(
        in: sessions.filter { seen.insert($0).inserted }, connection: connection)
    }

    private func notifyDecisions(in sessionIDs: [String], connection: ConnectionStore) async {
      for sessionID in sessionIDs {
        let contents: [SupervisionContent]
        do {
          contents = try await SupervisionNotifier.decisions(
            in: sessionID, openSessionID: sessionID,
            sessionTitle: connection.sessionList.session(sessionID)?.title, source: connection,
            isEnabled: preferences.isEnabled)
        } catch {
          report("Could not read the requests of a session: \(error.message)")
          continue
        }
        for content in contents where ledger.admit(content) {
          if !(await post(content)) { ledger.forget(content) }
        }
      }
      defaults.set(ledger.entries, forKey: Self.ledgerKey)
    }

    @discardableResult
    private func post(_ content: SupervisionContent) async -> Bool {
      let notification = UNMutableNotificationContent()
      notification.title = content.title
      notification.body = content.body
      notification.threadIdentifier = content.threadIdentifier
      notification.categoryIdentifier = content.category.rawValue
      notification.userInfo = content.payload.userInfo
      notification.targetContentIdentifier = content.payload.openSessionID
      notification.sound = .default
      notification.interruptionLevel = .active
      do {
        try await UNUserNotificationCenter.current().add(
          UNNotificationRequest(identifier: content.identifier, content: notification, trigger: nil)
        )
        logger.notice("Posted a \(content.category.rawValue, privacy: .public) notification")
        return true
      } catch {
        report("A notification could not be shown: \(error.localizedDescription)")
        return false
      }
    }

    /// Mirrors the attention badge on the app icon.
    /// - Parameter count: Sessions that need the user.
    public func setBadge(_ count: Int) async {
      do {
        try await UNUserNotificationCenter.current().setBadgeCount(count)
      } catch {
        report("The app badge could not be set: \(error.localizedDescription)")
      }
    }

    // MARK: - Background

    /// The scene went to the background: notify what is pending now, keep the streams for a
    /// short grace period so new requests still notify from live events, and schedule the poll.
    /// - Parameter connection: The scene's signed-in connection.
    public func didEnterBackground(_ connection: ConnectionStore) {
      scheduleRefresh()
      let application = UIApplication.shared
      var taskID = UIBackgroundTaskIdentifier.invalid
      let work = Task { [weak self] in
        guard let self else { return }
        await sweep(connection)
        do {
          try await Task.sleep(for: Self.backgroundGrace)
        } catch {
          return
        }
        await deliverPending(from: connection)
      }
      taskID = application.beginBackgroundTask(withName: "Omnigent attention") {
        work.cancel()
      }
      Task {
        await work.value
        application.endBackgroundTask(taskID)
      }
    }

    /// Asks for the next background poll.
    public func scheduleRefresh() {
      let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskIdentifier)
      request.earliestBeginDate = Date(timeIntervalSinceNow: Self.refreshInterval)
      do {
        try BGTaskScheduler.shared.submit(request)
      } catch {
        report("The background refresh could not be scheduled: \(error.localizedDescription)")
      }
    }

    private func run(_ task: BGTask) {
      scheduleRefresh()
      let work = Task { [weak self] () -> Bool in
        guard let self else { return false }
        return await poll()
      }
      task.expirationHandler = { work.cancel() }
      Task {
        let success = await work.value
        task.setTaskCompleted(success: success)
      }
    }

    /// One background poll: refresh the session list through the core, then sweep it.
    /// - Returns: Whether the poll reached the server.
    func poll() async -> Bool {
      guard let server = lastServerURL(), let connection = await connection(for: server) else {
        return false
      }
      let applied = connection.eventsApplied
      connection.core?.refreshSessions()
      for _ in 0..<40 where connection.eventsApplied == applied {
        do {
          try await Task.sleep(for: .milliseconds(250))
        } catch {
          return false
        }
      }
      await sweep(connection)
      return true
    }

    // MARK: - Actions

    /// A signed-in connection to `serverURL`: a scene's, or one opened with the saved sign-in.
    func connection(for serverURL: String) async -> ConnectionStore? {
      if let connection = connections.connection(for: serverURL) { return connection }
      let key = SupervisionConnections.key(serverURL)
      if let session = headless[key], session.isSignedIn { return session.connection }
      let session = ServerSession.live(keychain: KeychainModeSelection.current())
      headless[key] = session
      await session.signIn.connectNow(serverURL)
      guard session.isSignedIn else {
        headless[key] = nil
        return nil
      }
      return session.connection
    }

    func perform(_ action: SupervisionAction, text: String?, payload: SupervisionPayload) async {
      guard let connection = await connection(for: payload.serverURL) else {
        await post(.failure(.notConnected, payload: payload, sessionTitle: nil))
        return
      }
      let title = connection.sessionList.session(payload.openSessionID)?.title
      do {
        try await SupervisionActionRouter.perform(
          action, text: text, payload: payload, source: connection)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [
          "\(payload.serverURL)/c/\(payload.sessionID)/failure"
        ])
      } catch {
        report("A notification action did not run: \(error.message)")
        await post(.failure(error, payload: payload, sessionTitle: title))
      }
    }

    func report(_ message: String) {
      lastError = message
      logger.error("\(message, privacy: .public)")
    }
  }

  extension PhoneSupervision: UNUserNotificationCenterDelegate {
    /// Shows banners while the app is open; the core already skips the session on screen.
    nonisolated public func userNotificationCenter(
      _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
      withCompletionHandler completionHandler:
        @escaping (UNNotificationPresentationOptions) ->
        Void
    ) {
      completionHandler([.banner, .list, .sound])
    }

    /// Opens the session on a tap, or runs Approve, Deny or Reply. The completion handler is
    /// called on the main thread: UIKit snapshots the app from it.
    nonisolated public func userNotificationCenter(
      _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
      withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
      let identifier = response.actionIdentifier
      let text = (response as? UNTextInputNotificationResponse)?.userText
      let payload = Result { () throws(SupervisionError) in
        try SupervisionPayload(userInfo: response.notification.request.content.userInfo)
      }
      Task { @MainActor in
        await handle(identifier: identifier, text: text, payload: payload)
        completionHandler()
      }
    }
  }

  extension PhoneSupervision {
    func handle(
      identifier: String, text: String?, payload read: Result<SupervisionPayload, SupervisionError>
    ) async {
      let payload: SupervisionPayload
      do {
        payload = try read.get()
      } catch {
        report("Ignored a notification: \(error.message)")
        return
      }
      if identifier == UNNotificationDefaultActionIdentifier {
        pendingOpen = payload
        return
      }
      guard let action = SupervisionAction(rawValue: identifier) else { return }
      await perform(action, text: text, payload: payload)
    }
  }

#endif
