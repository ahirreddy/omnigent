#if os(macOS)
  import AppKit
  import Foundation
  import ObjectiveC
  import Testing
  import UserNotifications

  @testable import OmnigentDesktop

  /// Stands in for `UNUserNotificationCenter`, so nothing reaches the real Notification Center.
  final class FakeNotificationSystem: NotificationSystemCenter {
    weak var delegate: (any UNUserNotificationCenterDelegate)?
    var categories: Set<UNNotificationCategory> = []
    var requests: [UNNotificationRequest] = []
    var removedIdentifiers: [[String]] = []
    var requestedOptions: [UNAuthorizationOptions] = []
    var authorizationAnswer = true
    var authorizationFailure: (any Error)?
    var addFailure: (any Error)?
    var status = UNAuthorizationStatus.notDetermined

    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {
      self.categories = categories
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
      await Task.yield()  // The real call suspends for the system's answer.
      requestedOptions.append(options)
      if let authorizationFailure { throw authorizationFailure }
      return authorizationAnswer
    }

    func notificationSettings() async -> UNNotificationSettings {
      await Task.yield()  // The real call suspends for the system's answer.
      // swiftlint:disable:next force_try
      let settings = try! SystemNotificationObjects.make(UNNotificationSettings.self)
      settings.setValue(status.rawValue, forKey: "authorizationStatus")
      return settings
    }

    func add(_ request: UNNotificationRequest) async throws {
      await Task.yield()  // The real call suspends for the system's answer.
      if let addFailure { throw addFailure }
      requests.append(request)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
      removedIdentifiers.append(identifiers)
    }
  }

  /// Makes the objects only the system hands out, from an empty archive plus their values.
  enum SystemNotificationObjects {
    private struct NotDecoded: Error {}

    static func make<Object: NSObject & NSCoding>(_ type: Object.Type) throws -> Object {
      let archive = NSKeyedArchiver(requiringSecureCoding: false)
      archive.finishEncoding()
      let coder = try NSKeyedUnarchiver(forReadingFrom: archive.encodedData)
      coder.requiresSecureCoding = false
      guard let object = Object(coder: coder) else { throw NotDecoded() }
      return object
    }

    static func notification(
      identifier: String, userInfo: [AnyHashable: Any]
    ) throws -> UNNotification {
      let content = UNMutableNotificationContent()
      content.userInfo = userInfo
      let notification = try make(UNNotification.self)
      notification.setValue(
        UNNotificationRequest(identifier: identifier, content: content, trigger: nil),
        forKey: "request")
      return notification
    }

    static func response(
      action: String, notification: UNNotification, typed: String? = nil
    ) throws -> UNNotificationResponse {
      let response =
        try typed == nil
        ? make(UNNotificationResponse.self) : make(UNTextInputNotificationResponse.self)
      response.setValue(notification, forKey: "notification")
      response.setValue(action, forKey: "actionIdentifier")
      if let typed { response.setValue(typed, forKey: "userText") }
      return response
    }

    /// The delegate calls ignore their center, and the real one crashes outside an app bundle.
    static func ignoredCenter() throws -> UNUserNotificationCenter {
      let instance = class_createInstance(UNUserNotificationCenter.self, 0)
      guard let center = instance as? UNUserNotificationCenter else { throw NotDecoded() }
      return center
    }
  }

  /// What the wrapper asks of the system: posts, permission and delivered notifications.
  @MainActor
  @Suite("Notification delivery", .serialized)
  struct NotificationDeliveryTests {
    private struct Refused: Error {}

    private let system = FakeNotificationSystem()
    private let issues = IssueRecorder()

    init() { DesktopSideEffects.reset() }

    private func center() -> DesktopNotificationCenter {
      let system = system
      let issues = issues
      let center = DesktopNotificationCenter(reportIssue: { issues.issues.append($0) })
      center.systemCenter = { system }
      center.preferencesProvider = { NotificationPreferences(soundEnabled: true) }
      center.soundNameProvider = { "Basso" }
      return center
    }

    private func event(
      session: String = "s1", actions: NotificationActions? = nil
    ) throws -> DesktopNotificationEvent {
      let server = try url("https://a.test/mount")
      return DesktopNotificationEvent(
        kind: .elicitation, origin: try ServerOrigin(url: server), serverURL: server,
        sessionID: session, title: "Title", body: "Body", actions: actions)
    }

    @Test("a post carries the event's text, thread, buttons and a payload that opens it again")
    func posted() async throws {
      let actions = NotificationActions(
        categoryIdentifier: "approval", identifier: "request-1", context: ["request": "r1"])
      let decision = try await center().post(try event(actions: actions))
      guard case .deliver(let delivery) = decision else {
        Issue.record("expected delivery, got \(decision)")
        return
      }
      let request = try #require(system.requests.first)
      #expect(request.identifier == delivery.identifier)
      #expect(request.trigger == nil)
      #expect(request.content.title == delivery.title)
      #expect(request.content.body == "Body")
      #expect(request.content.threadIdentifier == delivery.threadIdentifier)
      #expect(request.content.categoryIdentifier == "approval")
      #expect(request.content.sound == nil, "the app plays the chosen sound itself")
      let activation = DesktopNotificationCenter.activation(from: request.content.userInfo)
      #expect(activation?.route == .conversation(sessionID: "s1"))
      #expect(activation?.serverURL == (try url("https://a.test/mount")))
    }

    @Test("a post with no buttons leaves the category empty")
    func noCategory() async throws {
      try await center().post(try event())
      #expect(system.requests.first?.content.categoryIdentifier.isEmpty == true)
    }

    @Test("a repeat within the throttle plays the sound once, and each post bounces the Dock")
    func soundAndDock() async throws {
      let center = center()
      try await center.post(try event())
      try await center.post(try event())
      #expect(DesktopSideEffects.state.playedSounds == ["Basso"])
      #expect(DesktopSideEffects.state.attentionRequests == 2)
      #expect(system.requests.count == 2)
    }

    @Test("with the app in front, a post doesn't bounce the Dock")
    func noBounceInFront() async throws {
      let center = center()
      center.contextProvider = {
        NotificationContext(appIsActive: true, viewing: nil, activeServerCount: 1)
      }
      try await center.post(try event())
      #expect(system.requests.count == 1)
      #expect(DesktopSideEffects.state.attentionRequests == 0)
    }

    @Test("a sound that won't play is reported, and the notification still shows")
    func soundFails() async throws {
      DesktopSideEffects.state.soundsPlay = false
      try await center().post(try event())
      #expect(system.requests.count == 1)
      guard case .notificationFailed(.soundUnavailable("Basso")) = issues.issues.first else {
        Issue.record("expected a sound issue, got \(issues.issues)")
        return
      }
    }

    @Test("a post the system refuses throws, with no sound or bounce")
    func postRefused() async throws {
      system.addFailure = Refused()
      let refused = try event()
      do {
        try await center().post(refused)
        Issue.record("expected the post to fail")
      } catch {
        guard case .post(let cause) = error, cause is Refused else {
          Issue.record("expected the system's refusal, got \(error)")
          return
        }
      }
      #expect(DesktopSideEffects.state.playedSounds.isEmpty)
      #expect(DesktopSideEffects.state.attentionRequests == 0)
    }

    @Test("asking for permission covers the Dock badge, and rereads the answer")
    func requestsPermission() async throws {
      let center = center()
      system.status = .authorized
      #expect(try await center.requestAuthorization())
      #expect(system.requestedOptions == [[.alert, .sound, .badge]])
      #expect(center.authorization == .authorized)
      system.authorizationAnswer = false
      system.status = .denied
      #expect(try await !center.requestAuthorization())
      #expect(center.authorization == .denied)
    }

    @Test("a permission request that fails throws and leaves the known answer")
    func permissionFails() async throws {
      let center = center()
      system.authorizationFailure = Refused()
      do {
        try await center.requestAuthorization()
        Issue.record("expected the request to fail")
      } catch {
        guard case .authorization(let cause) = error, cause is Refused else {
          Issue.record("expected the system's refusal, got \(error)")
          return
        }
      }
      #expect(center.authorization == .unknown)
    }

    @Test("every permission the system reports reads as its own state")
    func permissionStates() async throws {
      let center = center()
      let expected: [(UNAuthorizationStatus, DesktopNotificationCenter.Authorization)] = [
        (.notDetermined, .notDetermined), (.denied, .denied), (.authorized, .authorized),
        (.provisional, .provisional),
        (try #require(UNAuthorizationStatus(rawValue: 99)), .unknown),
      ]
      for (status, authorization) in expected {
        system.status = status
        try await center.refreshAuthorization()
        #expect(center.authorization == authorization, "\(status.rawValue)")
      }
    }

    @Test("the delegate, categories and removal reach the system")
    func systemCalls() throws {
      let center = center()
      try center.installAsDelegate()
      #expect(system.delegate === center)
      let category = UNNotificationCategory(
        identifier: "approval", actions: [], intentIdentifiers: [])
      try center.setCategories([category])
      #expect(system.categories == [category])
      let origin = try ServerOrigin(url: try url("https://a.test"))
      try center.removeDelivered(sessionID: "s1", origin: origin)
      #expect(
        system.removedIdentifiers == [
          [NotificationPolicy.identifier(origin: origin, sessionID: "s1")]
        ])
    }

    @Test("a banner for the conversation in front is held back when the system asks")
    func willPresent() async throws {
      let center = center()
      let server = try url("https://a.test")
      let origin = try ServerOrigin(url: server)
      center.contextProvider = {
        NotificationContext(
          appIsActive: true, viewing: ViewedSession(origin: origin, sessionID: "s1"),
          activeServerCount: 1)
      }
      let payload = DesktopNotificationCenter.payload(for: try event())
      let shown = try SystemNotificationObjects.notification(
        identifier: "n1", userInfo: [DesktopNotificationCenter.payloadKey: payload])
      let options = await center.userNotificationCenter(
        try SystemNotificationObjects.ignoredCenter(), willPresent: shown)
      #expect(options.isEmpty)
      let other = try SystemNotificationObjects.notification(identifier: "n2", userInfo: [:])
      let otherOptions = await center.userNotificationCenter(
        try SystemNotificationObjects.ignoredCenter(), willPresent: other)
      #expect(otherOptions == [.banner, .list])
    }

    @Test("the system's click opens the conversation, and its button keeps the typed reply")
    func didReceive() async throws {
      let center = center()
      var opened: [NotificationActivation] = []
      var answered: [NotificationActionResponse] = []
      center.onActivate = { opened.append($0) }
      center.onAction = { answered.append($0) }
      let actions = NotificationActions(
        categoryIdentifier: "approval", identifier: "request-1", context: ["request": "r1"])
      let payload = DesktopNotificationCenter.payload(for: try event(actions: actions))
      let note = try SystemNotificationObjects.notification(
        identifier: "n1", userInfo: [DesktopNotificationCenter.payloadKey: payload])
      await center.userNotificationCenter(
        try SystemNotificationObjects.ignoredCenter(),
        didReceive: try SystemNotificationObjects.response(
          action: UNNotificationDefaultActionIdentifier, notification: note))
      #expect(opened.map(\.route) == [.conversation(sessionID: "s1")])
      await center.userNotificationCenter(
        try SystemNotificationObjects.ignoredCenter(),
        didReceive: try SystemNotificationObjects.response(
          action: "reply", notification: note, typed: "ship it"))
      #expect(answered.map(\.text) == ["ship it"])
      #expect(answered.map(\.actionIdentifier) == ["reply"])
      #expect(answered.first?.context == ["request": "r1"])
    }
  }
#endif
