import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

/// Execution logs (the web's `ExecutionLogsPanel`): the session's raw items, and its
/// sub-agents' from the children it reports, or the events its open stream delivered.
enum ExecutionLogsAdapter {
  /// The sessions the logs offer: "main", then each sub-agent by its title.
  static func sessions(_ store: ConversationStore) -> [ExecutionLogSource.Session] {
    let children = store.sections.filter { $0.id.hasPrefix("child-") }.map { section in
      ExecutionLogSource.Session(
        id: section.sessionId ?? String(section.id.dropFirst("child-".count)),
        title: section.title, isMain: false)
    }
    return [ExecutionLogSource.Session(id: store.sessionID, title: "main", isMain: true)]
      + children
  }

  /// The logs' source over `store`.
  static func source(_ store: ConversationStore) -> ExecutionLogSource {
    ExecutionLogSource(
      sessions: sessions(store),
      read: { sessionID, cursor in
        do throws(CoreError) {
          let page = try await store.executionLogPage(of: sessionID, after: cursor)
          return .success(
            ExecutionLogPage(
              items: page.items.map {
                ExecutionLogItem(id: $0.id, compact: $0.compact, pretty: $0.pretty)
              },
              next: page.next))
        } catch {
          return .failure(LogReadFailure(message: error.message))
        }
      },
      isRunning: { store.isRunning },
      stream: { sessionID, after in
        store.streamLog(of: sessionID, after: after).map {
          ExecutionStreamEvent(
            index: $0.index,
            receivedAt: Date(timeIntervalSince1970: TimeInterval($0.receivedAtMs) / 1_000),
            compact: $0.compact, pretty: $0.pretty)
        }
      })
  }
}
