import Foundation
import ObjectiveC
import UserNotifications
import os

/// Keeps a test host off the system's notification center, which it shares with the user's own
/// copy of the app through the bundle identifier: nothing is shown, no permission is asked, and
/// the user's delivered notifications, categories and badge stay as they are.
enum TestHostNotifications {
  private typealias Add =
    @convention(c) (
      UNUserNotificationCenter, Selector, UNNotificationRequest,
      (@convention(block) (NSError?) -> Void)?
    ) -> Void
  private typealias Authorize =
    @convention(c) (
      UNUserNotificationCenter, Selector, UInt, (@convention(block) (Bool, NSError?) -> Void)?
    ) -> Void
  private typealias SetBadge =
    @convention(c) (
      UNUserNotificationCenter, Selector, Int, (@convention(block) (NSError?) -> Void)?
    ) -> Void
  private typealias TakeObject =
    @convention(c) (UNUserNotificationCenter, Selector, AnyObject?) -> Void
  private typealias TakeNothing = @convention(c) (UNUserNotificationCenter, Selector) -> Void

  private static let suppressed = OSAllocatedUnfairLock(initialState: 0)

  /// How many notifications were stopped here, so a test can see one would have shown.
  static var suppressedCount: Int { suppressed.withLock { $0 } }

  /// Replaces the center's methods for the rest of the process.
  /// - Throws: `TestHost.IsolationError.notificationsNotReplaced` when a method is missing.
  static func install() throws(TestHost.IsolationError) {
    let add: Add = { _, _, _, done in
      Self.suppressed.withLock { $0 += 1 }
      done?(nil)
    }
    try replace("addNotificationRequest:withCompletionHandler:", with: add)
    let authorize: Authorize = { _, _, _, done in done?(false, nil) }
    try replace("requestAuthorizationWithOptions:completionHandler:", with: authorize)
    let setBadge: SetBadge = { _, _, _, done in done?(nil) }
    try replace("setBadgeCount:withCompletionHandler:", with: setBadge)
    let ignoreObject: TakeObject = { _, _, _ in }
    for name in [
      "setDelegate:", "setNotificationCategories:",
      "removeDeliveredNotificationsWithIdentifiers:",
      "removePendingNotificationRequestsWithIdentifiers:",
    ] {
      try replace(name, with: ignoreObject)
    }
    let ignore: TakeNothing = { _, _ in }
    for name in ["removeAllDeliveredNotifications", "removeAllPendingNotificationRequests"] {
      try replace(name, with: ignore)
    }
  }

  /// Replaces one method of the center.
  /// - Throws: `TestHost.IsolationError.notificationsNotReplaced` when it has no such method.
  static func replace<Function>(_ name: String, with function: Function)
    throws(TestHost.IsolationError)
  {
    let selector = NSSelectorFromString(name)
    guard let method = unsafe class_getInstanceMethod(UNUserNotificationCenter.self, selector)
    else { throw .notificationsNotReplaced(method: name) }
    unsafe method_setImplementation(method, unsafeBitCast(function, to: IMP.self))
  }
}
