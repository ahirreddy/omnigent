public import Foundation
public import Observation

/// A conversation the menu bar extra lists because it needs the user.
nonisolated public struct AttentionSession: Identifiable, Hashable, Sendable {
  /// Why it needs attention.
  public enum Reason: Hashable, Sendable {
    /// An agent asked a question or for approval.
    case awaitingInput
    /// The last turn failed.
    case failed
    /// It has unread activity.
    case unread(count: Int)
  }

  /// The session ID, the `/c/<id>` path component.
  public var id: String
  /// Its title.
  public var title: String
  /// The full server URL including any workspace mount.
  public var serverURL: URL
  /// Why it is listed.
  public var reason: Reason
  /// When it last changed.
  public var updatedAt: Date

  /// Creates a session row.
  /// - Parameters:
  ///   - id: Session ID.
  ///   - title: Title.
  ///   - serverURL: Server URL.
  ///   - reason: Why it is listed.
  ///   - updatedAt: Last change.
  public init(id: String, title: String, serverURL: URL, reason: Reason, updatedAt: Date) {
    self.id = id
    self.title = title
    self.serverURL = serverURL
    self.reason = reason
    self.updatedAt = updatedAt
  }
}

/// What the menu bar extra shows about sessions. The app's stores conform with an `@Observable`
/// type so the menu updates live; `FakeMenuBarSessionSource` stands in until they do.
public protocol MenuBarSessionSource: AnyObject, Observable {
  /// Sessions that need the user, most urgent first.
  var sessionsNeedingAttention: [AttentionSession] { get }
  /// Sessions that need the user (pending decisions they can answer) across every connected
  /// server, shown next to the menu bar icon. The same number as the Dock badge.
  var unreadCount: Int { get }
}

/// A settable source for previews, the example app and tests.
@Observable
public final class FakeMenuBarSessionSource: MenuBarSessionSource {
  /// Sessions that need the user.
  public var sessionsNeedingAttention: [AttentionSession]
  /// Unread conversations.
  public var unreadCount: Int

  /// Creates a source.
  /// - Parameters:
  ///   - sessions: Sessions that need the user.
  ///   - unreadCount: Unread conversations.
  public init(sessions: [AttentionSession] = [], unreadCount: Int = 0) {
    sessionsNeedingAttention = sessions
    self.unreadCount = unreadCount
  }

  /// Three representative sessions on `serverURL`.
  /// - Parameters:
  ///   - serverURL: Their server.
  ///   - now: The reference time.
  /// - Returns: A populated source.
  public static func sample(serverURL: URL, now: Date = Date()) -> FakeMenuBarSessionSource {
    FakeMenuBarSessionSource(
      sessions: [
        AttentionSession(
          id: "conv_review", title: "Approve the database migration plan",
          serverURL: serverURL, reason: .awaitingInput, updatedAt: now.addingTimeInterval(-90)),
        AttentionSession(
          id: "conv_tests", title: "Fix flaky checkout tests", serverURL: serverURL,
          reason: .failed, updatedAt: now.addingTimeInterval(-1_200)),
        AttentionSession(
          id: "conv_docs", title: "Draft the 0.9 release notes", serverURL: serverURL,
          reason: .unread(count: 3), updatedAt: now.addingTimeInterval(-3_600)),
      ], unreadCount: 1)
  }
}
