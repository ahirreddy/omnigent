#if os(macOS)
  import Foundation
  import OmnigentCoreFFI
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentAppUI
  @testable import OmnigentDesktop
  @testable import OmnigentStores

  /// Posting what the core decided, and answering a request from its notification.
  @MainActor
  @Suite("Desktop notifications", .serialized, .timeLimit(.minutes(1)))
  struct DesktopAttentionTests {
    private final class Issues {
      var all: [DesktopIssue] = []
      var failedPosts: Int {
        all.count {
          if case .notificationFailed = $0 { true } else { false }
        }
      }
      var supervision: [String] {
        all.compactMap {
          if case .supervision(let message) = $0 { message } else { nil }
        }
      }
    }

    private static let server = URL(string: "http://127.0.0.1:6767")

    /// A shell that can't reach the system's notifications, so a post shows up as an issue.
    private func desktop() throws -> (DesktopController, Issues) {
      try #require(!DesktopNotificationCenter.isAvailable, "must never post on the user's Mac")
      let desktop = DesktopController(
        defaults: try scratchDefaults(), managedDomains: [],
        localServerCapability: .unavailable(.appSandbox))
      let issues = Issues()
      desktop.onIssue = { issues.all.append($0) }
      return (desktop, issues)
    }

    private func notification(
      _ kind: NotificationKind, session: String = "demo-design", title: String? = nil
    ) -> AttentionNotification {
      AttentionNotification(sessionId: session, kind: kind, title: title, body: "Body")
    }

    /// The approval the demo's design session waits on, as its notification carries it.
    private func approval(_ connection: ConnectionStore) async throws -> DesktopNotificationEvent {
      let url = try #require(connection.supervisedServerURL.flatMap(URL.init(string:)))
      let plain = try DesktopAttention.event(
        for: notification(.approval), serverURL: url, sessionTitle: "Design")
      DesktopAttention.ledger = SupervisionLedger()
      let events = try await DesktopAttention.actionableEvents(
        for: plain, sessionID: "demo-design", sessionTitle: "Design", source: connection)
      return try #require(events.first)
    }

    private func response(
      to event: DesktopNotificationEvent, action: String, text: String? = nil
    ) throws -> NotificationActionResponse {
      NotificationActionResponse(
        activation: NotificationActivation(
          serverURL: event.serverURL, route: .conversation(sessionID: try #require(event.sessionID))
        ),
        actionIdentifier: action, text: text, context: event.actions?.context ?? [:])
    }

    private func pending(_ connection: ConnectionStore) async throws -> Int {
      try await connection.pendingDecisions(sessionID: "demo-design").count { !$0.answered }
    }

    @Test("Each kind of notification says what happened, titled by what's known")
    func events() throws {
      let url = try #require(Self.server)
      let approval = try DesktopAttention.event(
        for: notification(.approval, title: "Mine"), serverURL: url, sessionTitle: "Listed")
      #expect(approval.kind == .elicitation)
      #expect(approval.title == "Mine")
      let finished = try DesktopAttention.event(
        for: notification(.completed), serverURL: url, sessionTitle: "Listed")
      #expect(finished.kind == .turnFinished)
      #expect(finished.title == "Listed")
      let failed = try DesktopAttention.event(
        for: notification(.failed), serverURL: url, sessionTitle: nil)
      #expect(failed.kind == .turnFailed)
      #expect(failed.title == "Omnigent")
      let offline = try DesktopAttention.event(
        hostWentOffline: HostWentOffline(hostID: "h1", name: "Mac"), serverURL: url)
      #expect(offline.kind == .runnerOffline(runnerID: "h1"))
      #expect(offline.title == "Mac went offline")
    }

    @Test("A went-offline host on an unreadable server is reported and not posted")
    func offlineHostOnABadServer() async throws {
      let connection = try await connectedDemo().connection
      let notifications = try #require(connection.notifications)
      let (desktop, issues) = try desktop()
      let online = CreationHost(
        hostId: "h1", name: "Mac", status: "online", sandboxProvider: nil,
        configuredHarnesses: nil, isAvailable: true)
      notifications.offlineHosts.observe([online])
      var offline = online
      offline.status = "offline"
      notifications.offlineHosts.observe([offline])
      let url = try #require(URL(string: "file:///nope"))
      await DesktopAttention.deliverHostsWentOffline(connection, serverURL: url, desktop: desktop)
      #expect(issues.all.contains { if case .invalidServerURL = $0 { true } else { false } })
      #expect(issues.failedPosts == 0)
    }

    @Test("A failed action whose notification named an unreadable server says so and posts nothing")
    func failureOnABadServer() async throws {
      let connection = try await connectedDemo().connection
      let (desktop, issues) = try desktop()
      let connections = SupervisionConnections()
      connections.register(connection)
      let event = try await approval(connection)
      var approve = try response(to: event, action: SupervisionAction.approve.rawValue)
      let url = try #require(URL(string: "file:///nope"))
      approve.activation = NotificationActivation(serverURL: url, route: approve.activation.route)
      await DesktopSupervision.perform(
        approve, desktop: desktop, connections: connections,
        evaluate: { false })
      #expect(issues.all.contains { if case .invalidServerURL = $0 { true } else { false } })
      #expect(issues.failedPosts == 0)
    }

    @Test("A request gets one notification with its buttons, and only once")
    func actionableOnce() async throws {
      let connection = try await connectedDemo().connection
      let event = try await approval(connection)
      #expect(event.actions?.categoryIdentifier.isEmpty == false)
      let plain = try DesktopAttention.event(
        for: notification(.approval), serverURL: event.serverURL, sessionTitle: nil)
      let again = try await DesktopAttention.actionableEvents(
        for: plain, sessionID: "demo-design", sessionTitle: nil, source: connection)
      #expect(again.isEmpty, "the same request doesn't alert twice")
    }

    @Test("Pending notifications post, reading the session's requests for an approval")
    func delivering() async throws {
      let connection = try await connectedDemo().connection
      let notifications = try #require(connection.notifications)
      let (desktop, issues) = try desktop()
      let url = try #require(connection.supervisedServerURL.flatMap(URL.init(string:)))
      DesktopAttention.ledger = SupervisionLedger()
      notifications.notify(notification(.approval))
      notifications.notify(notification(.failed, session: "demo-notes"))
      await DesktopAttention.deliverPending(
        notifications, list: connection.sessionList, serverURL: url, desktop: desktop,
        source: connection)
      #expect(notifications.pending.isEmpty)
      #expect(issues.failedPosts == 2, "\(issues.all)")
    }

    @Test("A request that can't be read still notifies, without buttons, and reports why")
    func unreadableRequests() async throws {
      let connection = try await connectedDemo().connection
      let notifications = try #require(connection.notifications)
      let (desktop, issues) = try desktop()
      let url = try #require(Self.server)
      notifications.notify(notification(.approval, session: "gone"))
      await DesktopAttention.deliverPending(
        notifications, list: connection.sessionList, serverURL: url, desktop: desktop,
        source: connection)
      #expect(issues.supervision.first?.hasPrefix("Requests of gone not read") == true)
      #expect(issues.failedPosts == 1)
    }

    @Test("A notification with no real server is reported and skipped")
    func aBadServer() async throws {
      let connection = try await connectedDemo().connection
      let notifications = try #require(connection.notifications)
      let (desktop, issues) = try desktop()
      let url = try #require(URL(string: "file:///nope"))
      notifications.notify(notification(.failed))
      await DesktopAttention.deliverPending(
        notifications, list: connection.sessionList, serverURL: url, desktop: desktop)
      let invalid = issues.all.contains {
        if case .invalidServerURL = $0 { true } else { false }
      }
      #expect(invalid)
      #expect(issues.failedPosts == 0)
    }

    @Test("Approve asks who you are first, then answers; refused, it answers nothing")
    func approving() async throws {
      let connection = try await connectedDemo().connection
      let (desktop, issues) = try desktop()
      let connections = SupervisionConnections()
      connections.register(connection)
      let event = try await approval(connection)
      let before = try await pending(connection)
      let approve = try response(to: event, action: SupervisionAction.approve.rawValue)

      await DesktopSupervision.perform(
        approve, desktop: desktop, connections: connections,
        evaluate: { false })
      #expect(try await pending(connection) == before, "nothing was sent")
      #expect(issues.supervision.first?.hasPrefix("A notification action did not run") == true)
      #expect(issues.failedPosts == 1, "the failure tells the user in a notification")

      await DesktopSupervision.perform(
        approve, desktop: desktop, connections: connections,
        evaluate: { true })
      #expect(try await pending(connection) == before - 1)
    }

    @Test("Deny needs no Touch ID; an unknown action or a broken payload is reported")
    func denyingAndBadResponses() async throws {
      let connection = try await connectedDemo().connection
      let (desktop, issues) = try desktop()
      let connections = SupervisionConnections()
      connections.register(connection)
      let event = try await approval(connection)
      let before = try await pending(connection)

      await DesktopSupervision.perform(
        try response(to: event, action: "omnigent.unknown"), desktop: desktop,
        connections: connections)
      #expect(issues.supervision.last?.hasPrefix("Unknown notification action") == true)

      var broken = try response(to: event, action: SupervisionAction.deny.rawValue)
      broken.context = [:]
      await DesktopSupervision.perform(broken, desktop: desktop, connections: connections)
      #expect(issues.supervision.last?.hasPrefix("Ignored a notification action") == true)
      #expect(try await pending(connection) == before)

      await DesktopSupervision.perform(
        try response(to: event, action: SupervisionAction.deny.rawValue), desktop: desktop,
        connections: connections)
      #expect(try await pending(connection) == before - 1)
    }

    @Test("An action for a server no window is signed in to says so")
    func notConnected() async throws {
      let connection = try await connectedDemo().connection
      let (desktop, issues) = try desktop()
      let event = try await approval(connection)
      await DesktopSupervision.perform(
        try response(to: event, action: SupervisionAction.deny.rawValue), desktop: desktop,
        connections: SupervisionConnections())
      #expect(issues.supervision.first?.hasPrefix("A notification action did not run") == true)
    }

    @Test("Installing makes notification actions run")
    func installing() async throws {
      let connection = try await connectedDemo().connection
      let (desktop, _) = try desktop()
      let connections = SupervisionConnections()
      connections.register(connection)
      DesktopSupervision.install(on: desktop, connections: connections)
      let event = try await approval(connection)
      let before = try await pending(connection)
      await desktop.notifications.onAction(
        try response(to: event, action: SupervisionAction.deny.rawValue))
      #expect(try await pending(connection) == before - 1)
    }

    @Test("A window posts what arrives, and a host going offline")
    func theModifier() async throws {
      let connection = try await connectedDemo().connection
      let notifications = try #require(connection.notifications)
      let (desktop, issues) = try desktop()
      let url = try #require(connection.supervisedServerURL.flatMap(URL.init(string:)))
      let screen = OffscreenWindow(
        Color.clear.desktopAttention(connection, serverURL: url, desktop: desktop), width: 100,
        height: 100)
      defer { screen.close() }
      try await pause(screen)
      #expect(SupervisionConnections.shared.connection(for: url.absoluteString) === connection)
      #expect(!notifications.isAllowed, "no permission yet")

      notifications.notify(notification(.failed))
      try await settle(screen, until: "the post") { issues.failedPosts == 1 }

      let online = CreationHost(
        hostId: "h1", name: "Mac", status: "online", sandboxProvider: nil,
        configuredHarnesses: nil, isAvailable: true)
      notifications.offlineHosts.observe([online])
      var offline = online
      offline.status = "offline"
      notifications.offlineHosts.observe([offline])
      try await settle(screen, until: "the offline post") { issues.failedPosts == 2 }
      #expect(notifications.offlineHosts.pending.isEmpty)
    }
  }

  extension DesktopAttentionTests {
    @Test("A passed, refused or failed check of who's approving decides whether it answers")
    func authenticating() async throws {
      try await DesktopSupervision.authenticate(evaluate: { true })
      struct NoFingerprint: Error {}
      let refusals: [() async throws -> Bool] = [{ false }, { throw NoFingerprint() }]
      for refusal in refusals {
        do {
          try await DesktopSupervision.authenticate(evaluate: refusal)
          Issue.record("a refusal authenticated")
        } catch {
          #expect(error == .authenticationFailed)
        }
      }
    }

    @Test("Notification buttons register where there's a center; a refusal is reported")
    func registeringCategories() throws {
      let (desktop, issues) = try desktop()
      DesktopSupervision.registerCategories(on: desktop, isAvailable: false)
      #expect(issues.all.isEmpty)
      // This process has no notification center, so registering is refused rather than posted.
      DesktopSupervision.registerCategories(on: desktop, isAvailable: true)
      #expect(issues.failedPosts == 1)
    }

    @Test("A turn end whose reply can't be read still notifies, and says the read failed")
    func unreadableReplyPreview() async throws {
      let connection = try await signedInStore(threeSessionServer())
      let notifications = try #require(connection.notifications)
      let (desktop, issues) = try desktop()
      notifications.notify(notification(.completed, session: "conv_missing"))
      let url = try #require(Self.server)
      await DesktopAttention.deliverPending(
        notifications, list: connection.sessionList, serverURL: url, desktop: desktop)
      #expect(issues.supervision.first?.hasPrefix("Reply preview not read") == true)
      #expect(issues.failedPosts == 1, "the plain notification still goes out")
    }
  }
#endif
