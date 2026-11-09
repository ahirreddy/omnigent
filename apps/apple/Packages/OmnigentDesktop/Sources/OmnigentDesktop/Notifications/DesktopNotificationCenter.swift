public import Foundation
public import Observation
public import UserNotifications

/// Why a notification operation failed.
nonisolated public enum DesktopNotificationError: Error, Sendable {
  /// The process has no bundle identifier (for example `swift run`), so
  /// `UNUserNotificationCenter` is unavailable.
  case unavailable
  /// Requesting authorization failed.
  case authorization(any Error)
  /// Adding the notification request failed.
  case post(any Error)
  /// The chosen system sound could not be loaded or played.
  case soundUnavailable(String)
}

/// A tapped notification, ready for `DesktopRouter.open(_:onServer:)`.
nonisolated public struct NotificationActivation: Hashable, Sendable {
  /// The full server URL the notification came from.
  public var serverURL: URL
  /// Where to go.
  public var route: DeepLinkRoute

  /// Creates an activation.
  /// - Parameters:
  ///   - serverURL: The full server URL.
  ///   - route: The destination.
  public init(serverURL: URL, route: DeepLinkRoute) {
    self.serverURL = serverURL
    self.route = route
  }
}

/// A notification action button the user chose.
nonisolated public struct NotificationActionResponse: Hashable, Sendable {
  /// The notification's server and session.
  public var activation: NotificationActivation
  /// The action's identifier.
  public var actionIdentifier: String
  /// Text typed into a text-input action.
  public var text: String?
  /// The routing identifiers the event's ``NotificationActions`` carried.
  public var context: [String: String]
}

/// `UNUserNotificationCenter` wrapper: applies `NotificationPolicy`, presents banners while the
/// app is frontmost (unlike Electron, where macOS hid them), plays the opt-in sound, bounces the
/// Dock and turns taps into routes.
@Observable
public final class DesktopNotificationCenter: NSObject {
  /// Notification permission.
  public enum Authorization: Hashable, Sendable {
    /// Not read yet.
    case unknown
    /// The user has not been asked.
    case notDetermined
    /// The user turned notifications off.
    case denied
    /// Allowed.
    case authorized
    /// Delivered quietly to Notification Center.
    case provisional
  }

  nonisolated static let payloadKey = "omnigent.desktop"

  /// The last authorization read.
  public internal(set) var authorization: Authorization = .unknown

  /// Frontmost window state, usually `ServerWindowRegistry.notificationContext`.
  @ObservationIgnored public var contextProvider: () -> NotificationContext
  /// The user's notification choices.
  @ObservationIgnored public var preferencesProvider: () -> NotificationPreferences
  /// The chosen system sound.
  @ObservationIgnored public var soundNameProvider: () -> String
  /// Called when the user clicks a notification.
  @ObservationIgnored public var onActivate: (NotificationActivation) -> Void = { _ in }
  /// Called when the user chooses an action button; returns when the action finished.
  @ObservationIgnored public var onAction: (NotificationActionResponse) async -> Void = { _ in }
  @ObservationIgnored private var throttle = SoundThrottle()
  @ObservationIgnored private let reportIssue: DesktopIssueReporter

  /// Creates the wrapper. Call `installAsDelegate()` from `applicationWillFinishLaunching`.
  /// - Parameter reportIssue: Receives sound and payload problems that do not fail a post.
  public init(reportIssue: @escaping DesktopIssueReporter = StandardErrorIssueReporter.report) {
    self.reportIssue = reportIssue
    contextProvider = {
      NotificationContext(appIsActive: false, viewing: nil, activeServerCount: 0)
    }
    preferencesProvider = { NotificationPreferences() }
    soundNameProvider = { SystemSounds.defaultName }
    super.init()
  }

  /// Whether this process can use `UNUserNotificationCenter`.
  public static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

  private func center() throws(DesktopNotificationError) -> UNUserNotificationCenter {
    guard Self.isAvailable else { throw .unavailable }
    return UNUserNotificationCenter.current()
  }

  /// Becomes the center's delegate so banners show while frontmost and taps are routed.
  /// Install before launch finishes so a tap that launched the app is delivered.
  /// - Throws: `DesktopNotificationError.unavailable` outside an app bundle.
  public func installAsDelegate() throws(DesktopNotificationError) {
    try center().delegate = self
  }

  /// Registers the categories whose action buttons notifications may use.
  /// - Parameter categories: The categories.
  /// - Throws: `DesktopNotificationError.unavailable` outside an app bundle.
  public func setCategories(_ categories: Set<UNNotificationCategory>)
    throws(DesktopNotificationError)
  {
    try center().setNotificationCategories(categories)
  }

  /// Asks for alert, sound and badge permission. The badge is needed for the Dock count.
  /// - Returns: Whether notifications are allowed.
  /// - Throws: `DesktopNotificationError` when the request fails.
  @discardableResult
  public func requestAuthorization() async throws(DesktopNotificationError) -> Bool {
    let center = try center()
    let granted: Bool
    do {
      granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
    } catch {
      throw .authorization(error)
    }
    try await refreshAuthorization()
    return granted
  }

  /// Re-reads the permission, for example when the Settings window appears.
  /// - Throws: `DesktopNotificationError.unavailable` outside an app bundle.
  public func refreshAuthorization() async throws(DesktopNotificationError) {
    let settings = try await center().notificationSettings()
    authorization =
      switch settings.authorizationStatus {
      case .notDetermined: .notDetermined
      case .denied: .denied
      case .authorized, .ephemeral: .authorized
      case .provisional: .provisional
      @unknown default: .unknown
      }
  }

  /// Applies the policy and posts the notification if it passes.
  /// - Parameter event: The event.
  /// - Returns: The policy decision.
  /// - Throws: `DesktopNotificationError` when the center is unavailable or rejects the request.
  @discardableResult
  public func post(_ event: DesktopNotificationEvent) async throws(DesktopNotificationError)
    -> NotificationDecision
  {
    let decision = NotificationPolicy.decide(
      event, context: contextProvider(), preferences: preferencesProvider())
    guard case .deliver(let delivery) = decision else { return decision }
    let center = try center()

    let content = UNMutableNotificationContent()
    content.title = delivery.title
    content.body = delivery.body
    content.threadIdentifier = delivery.threadIdentifier
    if let category = delivery.categoryIdentifier { content.categoryIdentifier = category }
    content.userInfo = [Self.payloadKey: Self.payload(for: event)]
    // Sound is played by the app so it can be chosen, opt-in and throttled per session.
    content.sound = nil
    let request = UNNotificationRequest(
      identifier: delivery.identifier, content: content, trigger: nil)
    do {
      try await center.add(request)
    } catch {
      throw .post(error)
    }

    if delivery.wantsSound, throttle.shouldPlay(key: delivery.identifier, now: Date()) {
      do {
        try SystemSounds.play(soundNameProvider())
      } catch {
        reportIssue(.notificationFailed(error))
      }
    }
    if delivery.requestsAttention { DockAttention.requestAttention() }
    return decision
  }

  /// Removes delivered notifications for a conversation, for example once the user opens it.
  /// - Parameters:
  ///   - sessionID: The conversation.
  ///   - origin: Its server.
  /// - Throws: `DesktopNotificationError.unavailable` outside an app bundle.
  public func removeDelivered(sessionID: String, origin: ServerOrigin)
    throws(DesktopNotificationError)
  {
    try center().removeDeliveredNotifications(
      withIdentifiers: [NotificationPolicy.identifier(origin: origin, sessionID: sessionID)])
  }

  static func payload(for event: DesktopNotificationEvent) -> [String: any Sendable] {
    var payload: [String: any Sendable] = [
      "version": 1, "serverURL": event.serverURL.absoluteString,
    ]
    if let sessionID = event.sessionID { payload["sessionID"] = sessionID }
    if let actions = event.actions { payload["actionContext"] = actions.context }
    return payload
  }

  /// Parses a payload written by `payload(for:)`. Other versions and shapes are rejected.
  nonisolated static func activation(from userInfo: [AnyHashable: Any]) -> NotificationActivation? {
    guard let payload = userInfo[payloadKey] as? [String: Any],
      payload["version"] as? Int == 1,
      let rawURL = payload["serverURL"] as? String,
      let serverURL = URL(string: rawURL)
    else { return nil }
    guard let sessionID = payload["sessionID"] as? String else {
      return NotificationActivation(serverURL: serverURL, route: .home)
    }
    guard !sessionID.isEmpty, !sessionID.contains("/") else { return nil }
    return NotificationActivation(
      serverURL: serverURL, route: .conversation(sessionID: sessionID))
  }

  private func presentationOptions(for activation: NotificationActivation?)
    -> UNNotificationPresentationOptions
  {
    guard let activation, case .conversation(let sessionID) = activation.route else {
      return [.banner, .list]
    }
    let origin: ServerOrigin
    do {
      origin = try ServerOrigin(url: activation.serverURL)
    } catch {
      reportIssue(.invalidServerURL(activation.serverURL, error))
      return [.banner, .list]
    }
    let context = contextProvider()
    let viewing = ViewedSession(origin: origin, sessionID: sessionID)
    return context.appIsActive && context.viewing == viewing ? [] : [.banner, .list]
  }

  private func perform(_ action: NotificationActionResponse) async {
    await onAction(action)
  }

  private func activate(_ activation: NotificationActivation?, identifier: String) {
    guard let activation else {
      reportIssue(.unrecognizedNotificationPayload(identifier: identifier))
      return
    }
    onActivate(activation)
  }
}

extension DesktopNotificationCenter: UNUserNotificationCenterDelegate {
  /// Shows banners while frontmost unless the user is already viewing that conversation.
  nonisolated public func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    let activation = Self.activation(from: notification.request.content.userInfo)
    return await MainActor.run { presentationOptions(for: activation) }
  }

  /// Routes a click on the notification body to its conversation, and an action button to
  /// ``onAction``.
  nonisolated public func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
  ) async {
    let identifier = response.notification.request.identifier
    let userInfo = response.notification.request.content.userInfo
    let activation = Self.activation(from: userInfo)
    switch response.actionIdentifier {
    case UNNotificationDefaultActionIdentifier:
      await MainActor.run { activate(activation, identifier: identifier) }
    case UNNotificationDismissActionIdentifier:
      return
    default:
      let payload = userInfo[Self.payloadKey] as? [String: Any]
      guard let activation, let context = payload?["actionContext"] as? [String: String] else {
        await MainActor.run { activate(nil, identifier: identifier) }
        return
      }
      let action = NotificationActionResponse(
        activation: activation, actionIdentifier: response.actionIdentifier,
        text: (response as? UNTextInputNotificationResponse)?.userText, context: context)
      await perform(action)
    }
  }
}
