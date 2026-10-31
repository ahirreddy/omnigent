import Foundation

public enum SessionFilter: String, CaseIterable, Identifiable, Sendable {
  case all = "All sessions"
  case running = "Running"
  case needsResponse = "Needs response"
  case archived = "Archived"

  public var id: String { rawValue }
}

public enum SessionQuery {
  public static func matching(
    _ sessions: [SessionSummary], text: String = "", filter: SessionFilter = .all
  ) -> [SessionSummary] {
    let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return sessions.filter { session in
      let matchesFilter: Bool
      switch filter {
      case .all: matchesFilter = !session.isArchived
      case .running: matchesFilter = !session.isArchived && session.status == .running
      case .needsResponse: matchesFilter = session.status == .needsResponse
      case .archived: matchesFilter = session.isArchived
      }
      return matchesFilter
        && (query.isEmpty
          || [
            session.title, session.preview, session.workspace, session.agentName,
          ].contains { $0.localizedStandardContains(query) })
    }.sorted {
      if $0.isPinned != $1.isPinned { return $0.isPinned }
      if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
      return $0.id < $1.id
    }
  }
}
