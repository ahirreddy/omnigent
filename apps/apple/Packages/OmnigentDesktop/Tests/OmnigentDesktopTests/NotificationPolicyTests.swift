import Foundation
import Testing

@testable import OmnigentDesktop

// Suppression rules from web/src/hooks/useIdleNotifications.ts and the Electron notify handler.

@Suite("Notification policy")
struct NotificationPolicyTests {
  let server: ServerOrigin
  let otherServer: ServerOrigin
  let serverURL: URL

  init() throws {
    server = try ServerOrigin(serialized: "https://workspace.example.com")
    otherServer = try ServerOrigin(serialized: "http://localhost:8000")
    serverURL = try url("https://workspace.example.com/ml/omnigents")
  }

  private func event(
    _ kind: DesktopNotificationEvent.Kind = .turnFinished, session: String? = "conv_a"
  )
    -> DesktopNotificationEvent
  {
    DesktopNotificationEvent(
      kind: kind, origin: server, serverURL: serverURL, sessionID: session, title: "Fix the build",
      body: "Agent finished and is ready for your input.")
  }

  private func context(active: Bool, viewing: ViewedSession? = nil, servers: Int = 1)
    -> NotificationContext
  {
    NotificationContext(appIsActive: active, viewing: viewing, activeServerCount: servers)
  }

  private func delivery(_ decision: NotificationDecision) -> NotificationDelivery? {
    guard case .deliver(let delivery) = decision else { return nil }
    return delivery
  }

  @Test("delivers in the background and asks for attention")
  func background() throws {
    let decision = NotificationPolicy.decide(
      event(), context: context(active: false), preferences: NotificationPreferences())
    let delivery = try #require(delivery(decision))
    #expect(delivery.title == "Fix the build")
    #expect(delivery.identifier == "https://workspace.example.com/c/conv_a")
    #expect(delivery.threadIdentifier == "https://workspace.example.com")
    #expect(delivery.requestsAttention)
    #expect(!delivery.wantsSound)
  }

  @Test("suppresses the conversation being viewed in the frontmost window")
  func viewingSession() {
    let viewing = ViewedSession(origin: server, sessionID: "conv_a")
    for kind in [DesktopNotificationEvent.Kind.turnFinished, .turnFailed, .elicitation] {
      #expect(
        NotificationPolicy.decide(
          event(kind), context: context(active: true, viewing: viewing),
          preferences: NotificationPreferences()) == .suppress(.viewingSession))
    }
  }

  @Test("still notifies for the viewed conversation while the app is in the background")
  func viewingButInactive() throws {
    let viewing = ViewedSession(origin: server, sessionID: "conv_a")
    let decision = NotificationPolicy.decide(
      event(), context: context(active: false, viewing: viewing),
      preferences: NotificationPreferences())
    #expect(try #require(delivery(decision)).requestsAttention)
  }

  @Test("notifies for other conversations and for the same id on another server")
  func otherConversations() throws {
    for viewing in [
      ViewedSession(origin: server, sessionID: "conv_b"),
      ViewedSession(origin: otherServer, sessionID: "conv_a"),
    ] {
      let decision = NotificationPolicy.decide(
        event(), context: context(active: true, viewing: viewing),
        preferences: NotificationPreferences())
      let delivery = try #require(delivery(decision))
      #expect(!delivery.requestsAttention)
    }
  }

  @Test("runner offline is not suppressed by viewing a conversation")
  func runnerOffline() throws {
    let viewing = ViewedSession(origin: server, sessionID: "conv_a")
    let decision = NotificationPolicy.decide(
      event(.runnerOffline(runnerID: "mac-mini"), session: nil),
      context: context(active: true, viewing: viewing), preferences: NotificationPreferences())
    #expect(
      try #require(delivery(decision)).identifier == "https://workspace.example.com/runner/mac-mini"
    )
  }

  @Test("honors per-kind preferences")
  func disabledKinds() {
    let off = NotificationPreferences(turnEnded: false, elicitations: false, runnerOffline: false)
    for kind in [
      DesktopNotificationEvent.Kind.turnFinished, .turnFailed, .elicitation,
      .runnerOffline(runnerID: "r"),
    ] {
      #expect(
        NotificationPolicy.decide(event(kind), context: context(active: false), preferences: off)
          == .suppress(.disabledByUser))
    }
    let onlyElicitations = NotificationPreferences(turnEnded: false, runnerOffline: false)
    #expect(
      delivery(
        NotificationPolicy.decide(
          event(.elicitation), context: context(active: false), preferences: onlyElicitations))
        != nil)
  }

  @Test("prefixes the server when several servers are open")
  func multiServerTitle() throws {
    let decision = NotificationPolicy.decide(
      event(), context: context(active: false, servers: 2), preferences: NotificationPreferences())
    #expect(try #require(delivery(decision)).title == "[workspace.example.com] Fix the build")
  }

  @Test("sound is opt-in")
  func sound() throws {
    let decision = NotificationPolicy.decide(
      event(), context: context(active: false),
      preferences: NotificationPreferences(soundEnabled: true))
    #expect(try #require(delivery(decision)).wantsSound)
  }

  @Test("throttles sound per conversation")
  func throttle() {
    var throttle = SoundThrottle(interval: 3)
    let start = Date(timeIntervalSinceReferenceDate: 1_000)
    let plays = [
      throttle.shouldPlay(key: "a", now: start),
      throttle.shouldPlay(key: "a", now: start.addingTimeInterval(2.9)),
      throttle.shouldPlay(key: "b", now: start.addingTimeInterval(2.9)),
      throttle.shouldPlay(key: "a", now: start.addingTimeInterval(3)),
    ]
    #expect(plays == [true, false, true, true])
  }

  @Test("notification payloads round-trip to routes")
  @MainActor
  func payloadRoundTrip() throws {
    let payload = DesktopNotificationCenter.payload(for: event())
    let activation = DesktopNotificationCenter.activation(
      from: [DesktopNotificationCenter.payloadKey: payload])
    #expect(activation?.serverURL == serverURL)
    #expect(activation?.route == .conversation(sessionID: "conv_a"))

    let runner = DesktopNotificationCenter.payload(
      for: event(.runnerOffline(runnerID: "r"), session: nil))
    #expect(
      DesktopNotificationCenter.activation(from: [DesktopNotificationCenter.payloadKey: runner])?
        .route
        == .home)
  }

  @Test("rejects unknown payload versions and shapes")
  func rejectsPayloads() {
    let key = DesktopNotificationCenter.payloadKey
    #expect(DesktopNotificationCenter.activation(from: [:]) == nil)
    #expect(
      DesktopNotificationCenter.activation(from: [key: ["version": 2, "serverURL": "https://a"]])
        == nil)
    #expect(DesktopNotificationCenter.activation(from: [key: ["version": 1]]) == nil)
    #expect(
      DesktopNotificationCenter.activation(
        from: [key: ["version": 1, "serverURL": "https://a", "sessionID": "a/b"]]) == nil)
  }
}
