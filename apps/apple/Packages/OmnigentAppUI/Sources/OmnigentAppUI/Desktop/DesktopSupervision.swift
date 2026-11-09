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
      registerCategories(on: desktop, isAvailable: DesktopNotificationCenter.isAvailable)
      desktop.notifications.onAction = { response in
        await perform(response, desktop: desktop, connections: connections)
      }
    }

    /// Gives notifications their buttons where this process has a notification center.
    static func registerCategories(on desktop: DesktopController, isAvailable: Bool) {
      guard isAvailable else { return }
      do {
        try desktop.notifications.setCategories(SupervisionNotificationCategories.all)
      } catch {
        desktop.onIssue(.notificationFailed(error))
      }
    }

    /// Runs a notification's button, asking the device owner before an approval.
    static func perform(
      _ response: NotificationActionResponse, desktop: DesktopController,
      connections: SupervisionConnections
    ) async {
      await perform(
        response, desktop: desktop, connections: connections, evaluate: askTheDeviceOwner)
    }

    static func perform(
      _ response: NotificationActionResponse, desktop: DesktopController,
      connections: SupervisionConnections, evaluate: () async throws -> Bool
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
        if action == .approve { try await authenticate(evaluate: evaluate) }
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

    /// Whether the person passed `evaluate`; anything else is a failed authentication.
    static func authenticate(evaluate: () async throws -> Bool) async throws(SupervisionError) {
      let passed: Bool
      do {
        passed = try await evaluate()
      } catch {
        throw .authenticationFailed
      }
      guard passed else { throw .authenticationFailed }
    }

    // coverage:off shows the system's Touch ID prompt; VM flow backlog: approve from a notification
    /// Device owner authentication: Touch ID, a paired Watch, or the login password.
    private static func askTheDeviceOwner() async throws -> Bool {
      try await LAContext().evaluatePolicy(
        .deviceOwnerAuthentication, localizedReason: "approve a request from a notification")
    }
    // coverage:on

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
