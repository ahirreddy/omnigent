import AppKit
public import Foundation

/// Why connections should restart their fast reconnect schedule.
nonisolated public enum ReconnectTrigger: Hashable, Sendable {
  /// The Mac woke from sleep (Electron `powerMonitor` `resume`).
  case systemWake
  /// The screen was unlocked (Electron `unlock-screen`).
  case screenUnlock
  /// The user switched back to this login session.
  case sessionActivated
}

/// Turns system wake, screen unlock and session switches into an `AsyncStream`, so pending
/// reconnects retry within seconds of a VPN coming back instead of waiting out their backoff.
///
/// Wake and unlock often arrive together; consumers that reconnect should coalesce.
public final class SystemWakeMonitor {
  /// One notification that maps to a trigger.
  public struct Source: Sendable {
    /// The center that posts it.
    public var center: NotificationCenter
    /// The notification name.
    public var name: Notification.Name
    /// The trigger to emit.
    public var trigger: ReconnectTrigger

    /// Creates a source.
    /// - Parameters:
    ///   - center: The posting center.
    ///   - name: The notification name.
    ///   - trigger: The trigger to emit.
    public init(center: NotificationCenter, name: Notification.Name, trigger: ReconnectTrigger) {
      self.center = center
      self.name = name
      self.trigger = trigger
    }

    /// `NSWorkspace` wake and session notifications and the distributed screen-unlock
    /// notification.
    public static var system: [Self] {
      let workspace = NSWorkspace.shared.notificationCenter
      return [
        Self(center: workspace, name: NSWorkspace.didWakeNotification, trigger: .systemWake),
        Self(
          center: workspace, name: NSWorkspace.sessionDidBecomeActiveNotification,
          trigger: .sessionActivated),
        Self(
          center: DistributedNotificationCenter.default(),
          name: Notification.Name("com.apple.screenIsUnlocked"), trigger: .screenUnlock),
      ]
    }
  }

  /// Triggers in arrival order. Single consumer; the newest eight are buffered.
  public let triggers: AsyncStream<ReconnectTrigger>
  private let continuation: AsyncStream<ReconnectTrigger>.Continuation
  private var observers: [(center: NotificationCenter, token: any NSObjectProtocol)] = []

  /// Starts observing immediately.
  /// - Parameter sources: What to observe; tests pass their own center.
  public init(sources: [Source] = Source.system) {
    let (stream, continuation) = AsyncStream.makeStream(
      of: ReconnectTrigger.self, bufferingPolicy: .bufferingNewest(8))
    triggers = stream
    self.continuation = continuation
    observers = sources.map { source in
      let token = source.center.addObserver(forName: source.name, object: nil, queue: nil) { _ in
        continuation.yield(source.trigger)
      }
      return (source.center, token)
    }
  }

  isolated deinit {
    stop()
  }

  /// Stops observing and finishes the stream.
  public func stop() {
    for observer in observers {
      observer.center.removeObserver(observer.token)
    }
    observers.removeAll()
    continuation.finish()
  }
}
