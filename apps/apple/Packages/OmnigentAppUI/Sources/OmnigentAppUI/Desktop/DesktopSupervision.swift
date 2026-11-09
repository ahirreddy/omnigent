#if os(macOS)
  import Foundation
  import LocalAuthentication
  public import OmnigentDesktop
  import OmnigentStores

  /// Approve, Deny and Reply from the Mac's notifications. Approve asks for Touch ID or the
  /// password first; every action re-checks the request through the core of the window signed in
  /// to the notification's server (``SupervisionActionRouter``).
  public enum DesktopSupervision {
    /// Registers the categories and handles their actions.
    /// - Parameters:
    ///   - desktop: The shell.
    ///   - connections: The windows' connections.
    public static func install(
      on desktop: DesktopController, connections: SupervisionConnections = .shared
    ) {
      if DesktopNotificationCenter.isAvailable {
        do {
          try desktop.notifications.setCategories(SupervisionNotificationCategories.all)
        } catch {
          desktop.onIssue(.notificationFailed(error))
        }
      }
      desktop.notifications.onAction = { response in
        await perform(response, desktop: desktop, connections: connections)
      }
    }

    static func perform(
      _ response: NotificationActionResponse, desktop: DesktopController,
      connections: SupervisionConnections,
      authenticate: @MainActor () async throws(SupervisionError) -> Void = {
        try await Self.authenticate()
      }
    ) async {
      let payload: SupervisionPayload
      do {
        payload = try SupervisionPayload(context: response.context)
      } catch {
        desktop.onIssue(.supervision("Ignored a notification action: \(error.message)"))
        return
      }
      guard let action = SupervisionAction(rawValue: response.actionIdentifier) else {
        desktop.onIssue(.supervision("Unknown notification action \(response.actionIdentifier)"))
        return
      }
      do throws(SupervisionError) {
        if action == .approve { try await authenticate() }
        guard let connection = connections.connection(for: payload.serverURL) else {
          throw .notConnected
        }
        try await SupervisionActionRouter.perform(
          action, text: response.text, payload: payload, source: connection)
      } catch {
        desktop.onIssue(.supervision("A notification action did not run: \(error.message)"))
        await notifyFailure(error, response: response, desktop: desktop)
      }
    }

    /// Device owner authentication: Touch ID, a paired Watch, or the login password.
    static func authenticate() async throws(SupervisionError) {
      let context = LAContext()
      do {
        guard
          try await context.evaluatePolicy(
            .deviceOwnerAuthentication, localizedReason: "approve a request from a notification")
        else { throw SupervisionError.authenticationFailed }
      } catch {
        throw .authenticationFailed
      }
    }

    private static func notifyFailure(
      _ error: SupervisionError, response: NotificationActionResponse, desktop: DesktopController
    ) async {
      let serverURL = response.activation.serverURL
      let origin: ServerOrigin
      do {
        origin = try ServerOrigin(url: serverURL)
      } catch {
        desktop.onIssue(.invalidServerURL(serverURL, error))
        return
      }
      let sessionID: String? =
        if case .conversation(let id) = response.activation.route { id } else { nil }
      do {
        try await desktop.notifications.post(
          DesktopNotificationEvent(
            kind: .elicitation, origin: origin, serverURL: serverURL, sessionID: sessionID,
            title: "Omnigent", body: error.message))
      } catch {
        desktop.onIssue(.notificationFailed(error))
      }
    }
  }
#endif
