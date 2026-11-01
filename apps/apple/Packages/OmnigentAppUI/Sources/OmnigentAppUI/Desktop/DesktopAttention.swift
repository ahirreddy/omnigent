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

    /// Posts every pending notification of `notifications`.
    /// - Parameters:
    ///   - notifications: The store; its pending notifications are taken.
    ///   - list: Session titles.
    ///   - serverURL: The window's server.
    ///   - desktop: The shell.
    public static func deliverPending(
      _ notifications: NotificationsStore, list: SessionListStore, serverURL: URL,
      desktop: DesktopController
    ) async {
      for notification in notifications.take() {
        let event: DesktopNotificationEvent
        do {
          event = try Self.event(
            for: notification, serverURL: serverURL,
            sessionTitle: list.session(notification.sessionId)?.title)
        } catch {
          desktop.onIssue(.invalidServerURL(serverURL, error))
          continue
        }
        do {
          try await desktop.notifications.post(event)
        } catch {
          desktop.onIssue(.notificationFailed(error))
        }
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
        .onChange(of: pending, initial: true) { deliver() }
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
      Task {
        await DesktopAttention.deliverPending(
          notifications, list: list, serverURL: serverURL, desktop: desktop)
      }
    }
  }
#endif
