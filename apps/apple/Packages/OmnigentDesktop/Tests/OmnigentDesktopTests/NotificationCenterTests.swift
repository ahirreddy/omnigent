import AppKit
import Foundation
import Testing
import UserNotifications

@testable import OmnigentDesktop

/// What happens with a notification once delivered, and outside an app bundle.
@MainActor
@Suite("Notification center")
struct NotificationCenterTests {
  /// The center's problems, and the taps and actions it reported.
  @MainActor
  private final class Recorder {
    var issues: [DesktopIssue] = []
    var activations: [NotificationActivation] = []
    var actions: [NotificationActionResponse] = []
  }

  private func center(_ recorder: Recorder) -> DesktopNotificationCenter {
    let center = DesktopNotificationCenter(reportIssue: { recorder.issues.append($0) })
    center.onActivate = { recorder.activations.append($0) }
    center.onAction = { recorder.actions.append($0) }
    return center
  }

  private func userInfo(
    server: String = "https://a.test", session: String? = "s1", context: [String: String] = [:]
  ) -> [AnyHashable: Any] {
    var payload: [String: Any] = ["version": 1, "serverURL": server]
    if let session { payload["sessionID"] = session }
    if !context.isEmpty { payload["actionContext"] = context }
    return [DesktopNotificationCenter.payloadKey: payload]
  }

  private func event(_ kind: DesktopNotificationEvent.Kind = .turnFinished) throws
    -> DesktopNotificationEvent
  {
    let server = try url("https://a.test")
    return DesktopNotificationEvent(
      kind: kind, origin: try ServerOrigin(url: server), serverURL: server, sessionID: "s1",
      title: "Title", body: "Body")
  }

  @Test("clicking a notification opens its conversation")
  func tap() async throws {
    let recorder = Recorder()
    await center(recorder).respond(
      actionIdentifier: UNNotificationDefaultActionIdentifier, identifier: "n1",
      userInfo: userInfo(), text: nil)
    #expect(
      recorder.activations == [
        NotificationActivation(
          serverURL: try url("https://a.test"), route: .conversation(sessionID: "s1"))
      ])
    #expect(recorder.actions.isEmpty)
  }

  @Test("dismissing one does nothing")
  func dismiss() async {
    let recorder = Recorder()
    await center(recorder).respond(
      actionIdentifier: UNNotificationDismissActionIdentifier, identifier: "n1",
      userInfo: userInfo(), text: nil)
    #expect(recorder.activations.isEmpty)
    #expect(recorder.issues.isEmpty)
  }

  @Test("an action button answers with its text and routing context")
  func action() async throws {
    let recorder = Recorder()
    await center(recorder).respond(
      actionIdentifier: "approve", identifier: "n1",
      userInfo: userInfo(context: ["request": "r1"]), text: "yes")
    let answered = try #require(recorder.actions.first)
    #expect(answered.actionIdentifier == "approve")
    #expect(answered.text == "yes")
    #expect(answered.context == ["request": "r1"])
    #expect(answered.activation.route == .conversation(sessionID: "s1"))
  }

  @Test(
    "a payload this version doesn't understand is reported, not guessed at",
    arguments: [UNNotificationDefaultActionIdentifier, "approve"])
  func unknownPayload(actionIdentifier: String) async throws {
    let recorder = Recorder()
    await center(recorder).respond(
      actionIdentifier: actionIdentifier, identifier: "n1",
      userInfo: ["other": 1], text: nil)
    #expect(recorder.activations.isEmpty)
    #expect(recorder.actions.isEmpty)
    guard case .unrecognizedNotificationPayload("n1") = recorder.issues.first else {
      Issue.record("expected a payload issue, got \(recorder.issues)")
      return
    }
  }

  @Test("an action without routing context is reported too")
  func actionWithoutContext() async {
    let recorder = Recorder()
    await center(recorder).respond(
      actionIdentifier: "approve", identifier: "n1", userInfo: userInfo(), text: nil)
    #expect(recorder.actions.isEmpty)
    #expect(recorder.issues.count == 1)
  }

  @Test("a banner shows unless the user is already looking at that conversation")
  func banners() throws {
    let recorder = Recorder()
    let center = center(recorder)
    let server = try url("https://a.test")
    let origin = try ServerOrigin(url: server)
    let viewed = NotificationActivation(serverURL: server, route: .conversation(sessionID: "s1"))
    center.contextProvider = {
      NotificationContext(
        appIsActive: true, viewing: ViewedSession(origin: origin, sessionID: "s1"),
        activeServerCount: 1)
    }
    #expect(center.presentationOptions(for: viewed).isEmpty)
    let other = NotificationActivation(serverURL: server, route: .conversation(sessionID: "s2"))
    #expect(center.presentationOptions(for: other) == [.banner, .list])
    #expect(center.presentationOptions(for: nil) == [.banner, .list])
    let home = NotificationActivation(serverURL: server, route: .home)
    #expect(center.presentationOptions(for: home) == [.banner, .list])
    center.contextProvider = {
      NotificationContext(
        appIsActive: false, viewing: ViewedSession(origin: origin, sessionID: "s1"),
        activeServerCount: 1)
    }
    #expect(center.presentationOptions(for: viewed) == [.banner, .list], "in the background")
  }

  @Test("a notification from a server with a bad URL still shows, and it's reported")
  func badServerURL() throws {
    let recorder = Recorder()
    let bad = NotificationActivation(
      serverURL: try url("file:///tmp"), route: .conversation(sessionID: "s1"))
    #expect(center(recorder).presentationOptions(for: bad) == [.banner, .list])
    #expect(recorder.issues.count == 1)
  }

  @Test("outside an app bundle every system call says it's unavailable")
  func unavailable() async throws {
    let recorder = Recorder()
    let center = center(recorder)
    #expect(!DesktopNotificationCenter.isAvailable)
    #expect(throws: DesktopNotificationError.self) { try center.installAsDelegate() }
    #expect(throws: DesktopNotificationError.self) { try center.setCategories([]) }
    #expect(throws: DesktopNotificationError.self) {
      try center.removeDelivered(
        sessionID: "s1", origin: try ServerOrigin(url: try url("https://a.test")))
    }
    await #expect(throws: DesktopNotificationError.self) { try await center.requestAuthorization() }
    await #expect(throws: DesktopNotificationError.self) { try await center.refreshAuthorization() }
    await #expect(throws: DesktopNotificationError.self) { try await center.post(try event()) }
  }

  @Test("the policy decides before the system is touched, so a suppressed event posts nothing")
  func suppressedWithoutCenter() async throws {
    let recorder = Recorder()
    let center = center(recorder)
    center.preferencesProvider = {
      NotificationPreferences(
        turnEnded: false, elicitations: true, runnerOffline: true, soundEnabled: false)
    }
    let decision = try await center.post(try event())
    guard case .suppress = decision else {
      Issue.record("expected suppression, got \(decision)")
      return
    }
  }

  @Test("a Dock bounce can be requested")
  func bounce() {
    DockAttention.requestAttention()
    DockAttention.setBadge(0)
    #expect(NSApplication.shared.dockTile.badgeLabel == nil)
  }
}
