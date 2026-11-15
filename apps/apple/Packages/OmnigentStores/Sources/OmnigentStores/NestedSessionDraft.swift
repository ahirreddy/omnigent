import Foundation
public import OmnigentCoreFFI

/// The provisional sidebar row of an open Add nested agent composer (the web's nested session
/// draft): the last member of its source's family until the real session takes its place.
public struct NestedSessionDraft: Identifiable, Equatable, Sendable {
  /// What the row is called until the session has a title.
  public static let title = "New nested agent"

  /// The composer's key, kept from its opening until the real row replaces the draft.
  public let key: String
  /// The source session, as the composer read it.
  public var source: SessionSummary
  /// The token the next create carries, which the server's row for it carries too.
  public var token: String
  /// The created session, once the create answers.
  public var createdSessionID: String?
  /// When the composer opened, Unix seconds: the newest member, so the last of its family.
  public let createdAt: Int64

  /// The row's id: the composer's key, then the created session's, so the row the server sends
  /// for it takes the draft's place under the same identity.
  public var id: String { createdSessionID ?? key }

  /// Whether `session` is the server's row for this draft: the created session, or a row that
  /// carries the token of the create in flight.
  public func isReplaced(by session: SessionSummary) -> Bool {
    session.id == createdSessionID || session.clientCreateToken == token
  }
}

extension CreationStore {
  /// Shows the provisional row of the composer `key` beside `source`, or updates it.
  /// - Parameters:
  ///   - key: The composer's key.
  ///   - source: The source session.
  ///   - token: The token its next create carries.
  public func openNestedDraft(key: String, source: SessionSummary, token: String) {
    if let index = nestedDrafts.firstIndex(where: { $0.key == key }) {
      nestedDrafts[index].source = source
      nestedDrafts[index].token = token
      return
    }
    nestedDrafts.append(
      NestedSessionDraft(
        key: key, source: source, token: token,
        createdAt: Int64(Date().timeIntervalSince1970)))
  }

  /// The composer `key`'s create answered with `sessionID`: its row stands for that session now.
  public func nestedDraftCreated(key: String, sessionID: String) {
    guard let index = nestedDrafts.firstIndex(where: { $0.key == key }) else { return }
    nestedDrafts[index].createdSessionID = sessionID
  }

  /// The composer `key` left: a row whose session was never created goes with it.
  public func closeNestedDraft(key: String) {
    nestedDrafts.removeAll { $0.key == key && $0.createdSessionID == nil }
  }

  /// Drops the rows the list now shows for real (the created session with its family, or a row
  /// carrying a draft's token), and those whose source was archived before anything was created.
  /// - Parameter listed: Looks a session up in the list.
  public func retireNestedDrafts(listed: (String) -> SessionSummary?) {
    nestedDrafts.removeAll { draft in
      if let created = draft.createdSessionID {
        return listed(created)?.family != nil
      }
      return listed(draft.source.id)?.isArchived == true
    }
  }
}
