import NativeLabCore
import SwiftUI
import UIKit
import UserNotifications

@MainActor
final class NativeNotificationController: NSObject, ObservableObject,
  UNUserNotificationCenterDelegate
{
  static let shared = NativeNotificationController()

  @Published private(set) var permission: NativeNotificationPermission = .unknown
  @Published private(set) var status =
    "Background notifications are unavailable until push is configured."
  @Published private(set) var pendingRoute: NotificationRoute?
  @Published private(set) var selectedSessionIDs: [String] = []

  private let center = UNUserNotificationCenter.current()
  private var scope: NotificationScope?
  private var client: (any NativePushRegistrationClient)?
  private var capabilities: NativePushCapabilities?
  private var registrationRevision = UUID()
  private var token: String?
  private var generation = UUID()
  private var foreground = true
  private var activeSessionID: String?
  private var permissionRequestInFlight = false
  private var registrationTask: Task<Void, Never>?
  private var presented = NotificationLedger()
  private var activated = NotificationLedger()
  private let defaults = UserDefaults.standard

  private override init() {
    super.init()
    center.delegate = self
    if let data = defaults.data(forKey: "native-notifications.presented"),
      let ledger = try? JSONDecoder().decode(NotificationLedger.self, from: data)
    {
      presented = ledger
    }
    if let data = defaults.data(forKey: "native-notifications.activated"),
      let ledger = try? JSONDecoder().decode(NotificationLedger.self, from: data)
    {
      activated = ledger
    }
  }

  private var installationID: String {
    if let id = defaults.string(forKey: "native-notifications.installation") { return id }
    let id = UUID().uuidString.lowercased()
    defaults.set(id, forKey: "native-notifications.installation")
    return id
  }

  func configure(
    scope: NotificationScope?,
    registrationClient: (any NativePushRegistrationClient)? = nil
  ) async {
    let oldClient = client
    let changedScope = self.scope != scope
    let epoch = UUID()
    generation = epoch
    registrationTask?.cancel()
    registrationTask = nil
    self.scope = scope
    client = registrationClient
    capabilities = nil
    if changedScope {
      selectedSessionIDs = scope.flatMap { defaults.stringArray(forKey: subscriptionKey($0)) } ?? []
      token = nil
      center.removeAllDeliveredNotifications()
      UIApplication.shared.unregisterForRemoteNotifications()
    }
    if changedScope, let oldClient {
      do { try await oldClient.unregister(installationID: installationID) } catch {
        guard epoch == generation else { return }
        status =
          "Previous device registration could not be removed. Reconnect that account to disable its alerts."
        // Do not claim that logout revoked delivery on an unreachable server.
        return
      }
    }
    await refreshPermission()
    guard epoch == generation else { return }
    guard let scope,
      (scope.userID != "local" && scope.serverURL.hasPrefix("https://"))
        || scope.isLoopbackDevelopment,
      let registrationClient
    else {
      status =
        "Background notifications need a configured APNs server connection. Local development requires explicit loopback push configuration."
      return
    }
    guard Bundle.main.object(forInfoDictionaryKey: "NativeLabPushEnabled") as? Bool == true,
      !ProcessInfo.processInfo.arguments.contains("--ui-testing")
    else {
      status =
        "Background push is disabled in this build. Enable NativeLabPushEnabled with an APNs signing entitlement."
      return
    }
    do {
      let response = try await registrationClient.capabilities()
      guard epoch == generation else { return }
      guard response.available else {
        status =
          "Server push is unavailable: " + response.missingConfiguration.joined(separator: ", ")
        return
      }
      guard response.serverURL == scope.serverURL, response.workspaceID == scope.workspaceID,
        !scope.isLoopbackDevelopment || response.localDevelopment == true,
        response.topic == Bundle.main.bundleIdentifier,
        response.environment == Bundle.main.object(forInfoDictionaryKey: "NativeLabPushEnvironment")
          as? String
      else {
        status =
          "The server, workspace, app identifier, or APNs environment does not match this build."
        return
      }
      capabilities = response
      beginRemoteRegistrationIfAllowed()
    } catch {
      guard epoch == generation else { return }
      status =
        "Could not check the server's background notification configuration. Reconnect to retry."
    }
  }

  func requestPermission() async {
    guard !permissionRequestInFlight else { return }
    permissionRequestInFlight = true
    defer { permissionRequestInFlight = false }
    await refreshPermission()
    if permission == .notDetermined {
      do { _ = try await center.requestAuthorization(options: [.alert, .sound, .badge]) } catch {
        status = "Notification permission could not be requested. Try again in Settings."
      }
      await refreshPermission()
    }
    if permission == .denied {
      status = "Notifications are denied. Allow them in iOS Settings to receive alerts."
    } else {
      beginRemoteRegistrationIfAllowed()
    }
  }

  func refreshPermission() async {
    let settings = await center.notificationSettings()
    switch settings.authorizationStatus {
    case .notDetermined: permission = .notDetermined
    case .denied: permission = .denied
    case .authorized, .ephemeral: permission = .authorized
    case .provisional: permission = .provisional
    @unknown default: permission = .unknown
    }
  }

  private func beginRemoteRegistrationIfAllowed() {
    guard capabilities?.available == true else { return }
    guard permission == .authorized || permission == .provisional else {
      status =
        permission == .denied
        ? "Allow notifications in iOS Settings to receive background alerts."
        : "Allow notifications to receive approval requests and completed-session alerts."
      return
    }
    status = "Registering this device for background notifications…"
    UIApplication.shared.registerForRemoteNotifications()
  }

  func updateSessionIDs(_ ids: [String]) async {
    selectedSessionIDs = Array(Set(ids)).sorted()
    if let scope { defaults.set(selectedSessionIDs, forKey: subscriptionKey(scope)) }
    scheduleRegistration()
  }

  private func subscriptionKey(_ scope: NotificationScope) -> String {
    "native-notifications.sessions."
      + ((try? JSONEncoder().encode([scope.serverURL, scope.userID, scope.workspaceID])
        .base64EncodedString()) ?? "")
  }

  private func scheduleRegistration() {
    registrationRevision = UUID()
    guard registrationTask == nil else { return }
    let epoch = generation
    registrationTask = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled, epoch == generation {
        let revision = registrationRevision
        await registerToken()
        if revision == registrationRevision { break }
      }
      if epoch == generation { registrationTask = nil }
    }
  }

  func setForeground(_ active: Bool, activeSessionID: String?) {
    foreground = active
    self.activeSessionID = activeSessionID
    if active { Task { await refreshPermission() } }
  }

  func clearPendingRoute() { pendingRoute = nil }

  func didRegister(deviceToken: Data) {
    token = deviceToken.map { String(format: "%02x", $0) }.joined()
    scheduleRegistration()
  }

  func didFailRegistration() {
    token = nil
    status =
      "APNs device registration failed. Check the signing entitlement, environment, and device network."
  }

  private func registerToken() async {
    let sessionIDs = selectedSessionIDs
    guard let token, let client, let capabilities, let topic = capabilities.topic,
      let environment = capabilities.environment,
      permission == .authorized || permission == .provisional
    else { return }
    guard sessionIDs.count <= 500, sessionIDs.allSatisfy(NotificationRoute.validIdentifier) else {
      status = "Choose up to 500 valid owned sessions for background notifications."
      return
    }
    let epoch = generation
    do {
      try await client.register(
        NativePushRegistration(
          installationID: installationID,
          deviceToken: token, environment: environment, topic: topic, sessionIDs: sessionIDs))
      guard epoch == generation, !Task.isCancelled else { return }
      status =
        sessionIDs.isEmpty
        ? "Device registered. No owned sessions are selected for alerts."
        : "Background approval and completion alerts are enabled for \(sessionIDs.count) sessions."
    } catch {
      guard epoch == generation, !Task.isCancelled else { return }
      status = "Device registration was not confirmed by the server. Reconnect to retry."
    }
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    let route = NotificationRoute(userInfo: notification.request.content.userInfo)
    Task { @MainActor in
      guard let route, route.scope == scope,
        !(foreground && route.sessionID == activeSessionID), presented.insert(route)
      else {
        completionHandler([])
        return
      }
      defaults.set(try? JSONEncoder().encode(presented), forKey: "native-notifications.presented")
      completionHandler([.banner, .list, .sound])
    }
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let route = NotificationRoute(userInfo: response.notification.request.content.userInfo)
    let isTap = response.actionIdentifier == UNNotificationDefaultActionIdentifier
    Task { @MainActor in
      if isTap, let route, activated.insert(route) {
        // Keep cold-start taps until the host has loaded and scope-checked its account.
        pendingRoute = route
        defaults.set(try? JSONEncoder().encode(activated), forKey: "native-notifications.activated")
      }
      completionHandler()
    }
  }
}

@MainActor
final class NativeNotificationAppDelegate: NSObject, UIApplicationDelegate {
  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    _ = NativeNotificationController.shared
    return true
  }

  func application(
    _ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data
  ) {
    NativeNotificationController.shared.didRegister(deviceToken: token)
  }

  func application(
    _ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    NativeNotificationController.shared.didFailRegistration()
  }
}
