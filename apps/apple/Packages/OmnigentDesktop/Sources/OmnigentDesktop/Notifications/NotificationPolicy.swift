public import Foundation

// Pure notification decisions, matching web/src/hooks/useIdleNotifications.ts and the Electron
// notify handler: anything that needs attention notifies, except the conversation the user is
// looking at in the frontmost window. Covered by NotificationPolicyTests.

/// Something that may deserve a system notification.
nonisolated public struct DesktopNotificationEvent: Hashable, Sendable {
  /// What happened.
  public enum Kind: Hashable, Sendable {
    /// A turn settled (`running` to `idle`).
    case turnFinished
    /// A turn ended in failure.
    case turnFailed
    /// The agent is asking the user for input or approval.
    case elicitation
    /// A runner the session depends on went offline.
    case runnerOffline(runnerID: String)
  }

  /// What happened.
  public var kind: Kind
  /// The server that reported it.
  public var origin: ServerOrigin
  /// The full server URL including any workspace mount, used to reopen the right window.
  public var serverURL: URL
  /// The conversation, when the event belongs to one.
  public var sessionID: String?
  /// Notification title, usually the conversation title.
  public var title: String
  /// Notification body.
  public var body: String

  /// Creates an event.
  /// - Parameters:
  ///   - kind: What happened.
  ///   - origin: The reporting server's origin.
  ///   - serverURL: The full server URL.
  ///   - sessionID: The conversation, if any.
  ///   - title: Title text.
  ///   - body: Body text.
  public init(
    kind: Kind, origin: ServerOrigin, serverURL: URL, sessionID: String?, title: String,
    body: String
  ) {
    self.kind = kind
    self.origin = origin
    self.serverURL = serverURL
    self.sessionID = sessionID
    self.title = title
    self.body = body
  }
}

/// A conversation shown in a window.
nonisolated public struct ViewedSession: Hashable, Sendable {
  /// The window's server.
  public var origin: ServerOrigin
  /// The conversation.
  public var sessionID: String

  /// Creates a viewed session.
  /// - Parameters:
  ///   - origin: The server.
  ///   - sessionID: The conversation.
  public init(origin: ServerOrigin, sessionID: String) {
    self.origin = origin
    self.sessionID = sessionID
  }
}

/// The app state a notification decision depends on.
nonisolated public struct NotificationContext: Hashable, Sendable {
  /// Whether the app is frontmost.
  public var appIsActive: Bool
  /// The conversation in the key window, if any.
  public var viewing: ViewedSession?
  /// Distinct servers with an open window. Titles name the server when this exceeds one.
  public var activeServerCount: Int

  /// Creates a context.
  /// - Parameters:
  ///   - appIsActive: Whether the app is frontmost.
  ///   - viewing: The key window's conversation.
  ///   - activeServerCount: Distinct servers with a window.
  public init(appIsActive: Bool, viewing: ViewedSession?, activeServerCount: Int) {
    self.appIsActive = appIsActive
    self.viewing = viewing
    self.activeServerCount = activeServerCount
  }
}

/// Which notifications the user wants. Mirrors the Notifications settings tab.
nonisolated public struct NotificationPreferences: Hashable, Sendable {
  /// Notify when a turn finishes or fails.
  public var turnEnded: Bool
  /// Notify when an agent asks for input.
  public var elicitations: Bool
  /// Notify when a runner goes offline.
  public var runnerOffline: Bool
  /// Play a sound. Opt-in, as in the Electron app.
  public var soundEnabled: Bool

  /// Creates preferences. Every kind is on and sound is off by default.
  /// - Parameters:
  ///   - turnEnded: Turn-end notifications.
  ///   - elicitations: Input-request notifications.
  ///   - runnerOffline: Runner-offline notifications.
  ///   - soundEnabled: Sound.
  public init(
    turnEnded: Bool = true, elicitations: Bool = true, runnerOffline: Bool = true,
    soundEnabled: Bool = false
  ) {
    self.turnEnded = turnEnded
    self.elicitations = elicitations
    self.runnerOffline = runnerOffline
    self.soundEnabled = soundEnabled
  }
}

/// A notification to post.
nonisolated public struct NotificationDelivery: Hashable, Sendable {
  /// Request identifier. A newer notification for the same session replaces the older one.
  public var identifier: String
  /// Groups notifications by server in Notification Center.
  public var threadIdentifier: String
  /// Title, prefixed with `[host]` when several servers are open.
  public var title: String
  /// Body.
  public var body: String
  /// Whether to play the chosen sound, before per-session throttling.
  public var wantsSound: Bool
  /// Whether to bounce the Dock icon because the app is in the background.
  public var requestsAttention: Bool
}

/// Why a notification was not posted.
nonisolated public enum NotificationSuppression: Hashable, Sendable {
  /// The user turned this kind off.
  case disabledByUser
  /// The user is looking at this conversation in the frontmost window.
  case viewingSession
}

/// The outcome of `NotificationPolicy.decide`.
nonisolated public enum NotificationDecision: Hashable, Sendable {
  /// Post this notification.
  case deliver(NotificationDelivery)
  /// Do not notify.
  case suppress(NotificationSuppression)
}

/// Decides whether and how to notify.
nonisolated public enum NotificationPolicy {
  /// Decides for one event.
  /// - Parameters:
  ///   - event: The event.
  ///   - context: Frontmost window state.
  ///   - preferences: The user's choices.
  /// - Returns: The decision.
  public static func decide(
    _ event: DesktopNotificationEvent, context: NotificationContext,
    preferences: NotificationPreferences
  ) -> NotificationDecision {
    let enabled =
      switch event.kind {
      case .turnFinished, .turnFailed: preferences.turnEnded
      case .elicitation: preferences.elicitations
      case .runnerOffline: preferences.runnerOffline
      }
    guard enabled else { return .suppress(.disabledByUser) }

    if context.appIsActive, let sessionID = event.sessionID,
      context.viewing == ViewedSession(origin: event.origin, sessionID: sessionID)
    {
      return .suppress(.viewingSession)
    }

    let title =
      context.activeServerCount > 1 ? "[\(event.origin.authority)] \(event.title)" : event.title
    return .deliver(
      NotificationDelivery(
        identifier: identifier(for: event),
        threadIdentifier: event.origin.serialized,
        title: title,
        body: event.body,
        wantsSound: preferences.soundEnabled,
        requestsAttention: !context.appIsActive))
  }

  /// One identifier per conversation (or runner), so repeats replace rather than stack.
  /// - Parameter event: The event.
  /// - Returns: The request identifier.
  public static func identifier(for event: DesktopNotificationEvent) -> String {
    switch event.kind {
    case .runnerOffline(let runnerID): "\(event.origin.serialized)/runner/\(runnerID)"
    case .turnFinished, .turnFailed, .elicitation:
      identifier(origin: event.origin, sessionID: event.sessionID ?? "")
    }
  }

  /// The identifier shared by every notification for one conversation.
  /// - Parameters:
  ///   - origin: The server.
  ///   - sessionID: The conversation.
  /// - Returns: The request identifier.
  public static func identifier(origin: ServerOrigin, sessionID: String) -> String {
    "\(origin.serialized)/c/\(sessionID)"
  }
}

/// Plays a sound at most once per key in a window, so a burst of notifications for one
/// conversation sounds once while different conversations each still sound.
nonisolated public struct SoundThrottle: Sendable {
  /// The quiet period per key.
  public let interval: TimeInterval
  private var lastPlayed: [String: Date] = [:]

  /// Creates a throttle.
  /// - Parameter interval: Quiet period; Electron uses three seconds.
  public init(interval: TimeInterval = 3) {
    self.interval = interval
  }

  /// Records a play and returns `true` unless `key` played within the interval.
  /// - Parameters:
  ///   - key: The notification identifier.
  ///   - now: The current time.
  /// - Returns: Whether to play.
  public mutating func shouldPlay(key: String, now: Date) -> Bool {
    if let last = lastPlayed[key], now.timeIntervalSince(last) < interval { return false }
    lastPlayed = lastPlayed.filter { now.timeIntervalSince($0.value) < interval }
    lastPlayed[key] = now
    return true
  }
}
