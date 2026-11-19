import OmnigentCoreFFI
import OmnigentStores
import SwiftUI

/// Keeps the Inbox badge's counts current while the window shows, as the web's sidebar does: the
/// server's feeds every five minutes, and file comments whenever a session's count changes.
struct InboxFeedsPolling: ViewModifier {
  let connection: ConnectionStore

  /// How often the feeds are read again (the web's `refetchInterval`).
  static let interval: Duration = .seconds(300)

  /// The comments seen on this device, per server and account.
  static func seenCommentsKey(_ connection: ConnectionStore) -> String {
    "omnigent.inbox.seenComments.\(owner(connection))"
  }

  /// The failed automation runs marked read on this device, per server and account.
  static func readFailuresKey(_ connection: ConnectionStore) -> String {
    "omnigent.inbox.readAutomationRuns.\(owner(connection))"
  }

  private static func owner(_ connection: ConnectionStore) -> String {
    "\(connection.connectedServer?.baseUrl ?? "").\(connection.connectedServer?.userId ?? "")"
  }

  /// The server, account and feeds offered, and each return of the connection: a change starts
  /// the reads again.
  private var feedsSignature: String {
    let offered = connection.pages?.offered
    return "\(Self.owner(connection)):\(offered?.inboxItems == true):"
      + "\(offered?.automationInbox == true):\(connection.health.reconnections)"
  }

  /// Sessions with comments and their counts.
  private var commentSignature: [String] {
    connection.sessionList.sessionsByID.values.filter { $0.commentsCount > 0 }
      .map { "\($0.id):\($0.commentsCount)" }.sorted()
  }

  func body(content: Content) -> some View {
    content
      .task(id: feedsSignature) {
        guard let pages = connection.pages, connection.connectedServer != nil else { return }
        pages.bindSeenComments(key: Self.seenCommentsKey(connection))
        pages.feeds.bindReadFailures(key: Self.readFailuresKey(connection))
        while !Task.isCancelled {
          await pages.refreshInboxFeeds()
          try? await Task.sleep(for: Self.interval)
        }
      }
      .task(id: commentSignature) {
        await connection.pages?.refreshComments(Array(connection.sessionList.sessionsByID.values))
      }
  }
}
