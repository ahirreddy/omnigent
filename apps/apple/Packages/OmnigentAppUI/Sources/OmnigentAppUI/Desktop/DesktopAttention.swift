#if os(macOS)
  public import Foundation
  public import OmnigentCoreFFI
  public import OmnigentDesktop
  public import OmnigentStores
  public import SwiftUI

  /// Hands the notifications the core decided on (`NotificationsStore`) to the desktop's
  /// notification center, which applies the user's preferences, suppresses the conversation the
  /// user is looking at, and posts. Failures go to the desktop's issue reporter.
  public enum DesktopAttention {
    /// The desktop event for a core notification.
    /// - Parameters:
    ///   - notification: What the core decided to show.
    ///   - serverURL: The window's server.
    ///   - sessionTitle: The session's title, when the notification has none.
    /// - Returns: The event.
    /// - Throws: `ServerOriginError` when `serverURL` is not a server URL.
    public static func event(
      for notification: AttentionNotification, serverURL: URL, sessionTitle: String?
    ) throws(ServerOriginError) -> DesktopNotificationEvent {
      let kind: DesktopNotificationEvent.Kind =
        switch notification.kind {
        case .approval: .elicitation
        case .completed: .turnFinished
        case .failed: .turnFailed
        }
      return DesktopNotificationEvent(
        kind: kind, origin: try ServerOrigin(url: serverURL), serverURL: serverURL,
        sessionID: notification.sessionId,
        title: notification.title ?? sessionTitle ?? "Omnigent", body: notification.body)
    }

    /// Requests already posted with actions, so a later input request in the same session
    /// does not alert again for the earlier ones.
    @MainActor static var ledger = SupervisionLedger()

    /// Posts every pending notification of `notifications`. An input request becomes one
    /// actionable notification per request the session waits on, read fresh through `source`;
    /// when that read fails it posts the plain notification instead.
    /// - Parameters:
    ///   - notifications: The store; its pending notifications are taken.
    ///   - list: Session titles.
    ///   - serverURL: The window's server.
    ///   - desktop: The shell.
    ///   - source: The window's connection, for actionable requests.
    public static func deliverPending(
      _ notifications: NotificationsStore, list: SessionListStore, serverURL: URL,
      desktop: DesktopController, source: (any SupervisionDecisionSource)? = nil
    ) async {
      let (taken, failures) = await notifications.takeWithReplyPreviews()
      // Those turn ends still notify, with the default body.
      for failure in failures {
        desktop.onIssue(.supervision("Reply preview not read: \(failure.message)"))
      }
      for notification in taken {
        let event: DesktopNotificationEvent
        do {
          event = try Self.event(
            for: notification, serverURL: serverURL,
            sessionTitle: list.session(notification.sessionId)?.title)
        } catch {
          desktop.onIssue(.invalidServerURL(serverURL, error))
          continue
        }
        if notification.kind == .approval, let source, let sessionID = event.sessionID {
          do {
            let events = try await actionableEvents(
              for: event, sessionID: sessionID,
              sessionTitle: list.session(notification.sessionId)?.title, source: source)
            for actionable in events { await post(actionable, desktop: desktop) }
            continue
          } catch {
            // The plain notification still goes out; only its buttons are lost.
            desktop.onIssue(.supervision("Requests of \(sessionID) not read: \(error.message)"))
          }
        }
        await post(event, desktop: desktop)
      }
    }

    /// One event per request `sessionID` waits on that was not posted yet.
    static func actionableEvents(
      for event: DesktopNotificationEvent, sessionID: String, sessionTitle: String?,
      source: any SupervisionDecisionSource
    ) async throws(SupervisionError) -> [DesktopNotificationEvent] {
      let contents = try await SupervisionNotifier.decisions(
        in: sessionID, openSessionID: sessionID, sessionTitle: sessionTitle ?? event.title,
        source: source, isEnabled: { _ in true })
      return contents.filter { ledger.admit($0) }.map { content in
        var actionable = event
        actionable.title = content.title
        actionable.body = content.body
        actionable.actions = NotificationActions(
          categoryIdentifier: content.category.rawValue, identifier: content.identifier,
          context: content.payload.context)
        return actionable
      }
    }

    /// The notification for a host that went offline; the policy drops it when the user turned
    /// "A runner goes offline" off.
    /// - Parameters:
    ///   - host: The host.
    ///   - serverURL: The window's server.
    /// - Returns: The event.
    /// - Throws: `ServerOriginError` when `serverURL` is not a server URL.
    public static func event(
      hostWentOffline host: HostWentOffline, serverURL: URL
    ) throws(ServerOriginError) -> DesktopNotificationEvent {
      DesktopNotificationEvent(
        kind: .runnerOffline(runnerID: host.hostID), origin: try ServerOrigin(url: serverURL),
        serverURL: serverURL, sessionID: nil, title: "\(host.name) went offline",
        body: "Sessions on this host pause until it reconnects.")
    }

    /// Posts a notification per host that went offline since the last call.
    static func deliverHostsWentOffline(
      _ connection: ConnectionStore, serverURL: URL, desktop: DesktopController
    ) async {
      for host in connection.notifications?.offlineHosts.take() ?? [] {
        do {
          await post(try event(hostWentOffline: host, serverURL: serverURL), desktop: desktop)
        } catch {
          desktop.onIssue(.invalidServerURL(serverURL, error))
        }
      }
    }

    private static func post(_ event: DesktopNotificationEvent, desktop: DesktopController) async {
      do {
        try await desktop.notifications.post(event)
      } catch {
        desktop.onIssue(.notificationFailed(error))
      }
    }
  }

  extension View {
    /// Posts the core's notifications for this window's connection through the desktop, and
    /// tells the core whether notifications are allowed.
    /// - Parameters:
    ///   - connection: The window's connection.
    ///   - serverURL: The window's server, when bound.
    ///   - desktop: The shell.
    /// - Returns: The view.
    public func desktopAttention(
      _ connection: ConnectionStore, serverURL: URL?, desktop: DesktopController
    ) -> some View {
      modifier(
        DesktopAttentionModifier(connection: connection, serverURL: serverURL, desktop: desktop))
    }
  }

  struct DesktopAttentionModifier: ViewModifier {
    let connection: ConnectionStore
    let serverURL: URL?
    let desktop: DesktopController

    func body(content: Content) -> some View {
      let pending = connection.notifications?.pending.count ?? 0
      let authorization = desktop.notifications.authorization
      content
        .onChange(of: connection.isSignedIn, initial: true) {
          if connection.isSignedIn { SupervisionConnections.shared.register(connection) }
        }
        .onChange(of: pending, initial: true) { deliver() }
        .onChange(of: connection.notifications?.offlineHosts.pending.count ?? 0) { _, count in
          guard count > 0, let serverURL else { return }
          let (connection, desktop) = (connection, desktop)
          Task {
            await DesktopAttention.deliverHostsWentOffline(
              connection, serverURL: serverURL, desktop: desktop)
          }
        }
        .onChange(of: authorization, initial: true) {
          let allowed = authorization == .authorized || authorization == .provisional
          connection.notifications?.setAllowed(allowed)
        }
    }

    private func deliver() {
      guard let notifications = connection.notifications, !notifications.pending.isEmpty,
        let serverURL
      else { return }
      let list = connection.sessionList
      let desktop = desktop
      let connection = connection
      Task {
        await DesktopAttention.deliverPending(
          notifications, list: list, serverURL: serverURL, desktop: desktop, source: connection)
      }
    }
  }
#endif
