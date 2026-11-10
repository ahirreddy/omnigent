import Foundation
import Observation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import OmnigentWorkspaceUI
import SwiftUI
import UniformTypeIdentifiers

/// What the conversation's alert reports. An object, so closures made in an earlier render add
/// to the same list.
@Observable
final class ConversationFailures {
  var messages: [String] = []
}

/// A transcript in the web's `.jsonl` export format, for the save panel.
struct TranscriptExport: FileDocument {
  static let contentType = contentType(forExtension: "jsonl")
  static var readableContentTypes: [UTType] { [contentType] }

  let text: String

  /// The file's bytes.
  var fileContents: Data { Data(text.utf8) }

  init(text: String) {
    self.text = text
  }

  /// A transcript read from a file's bytes.
  init(fileContents: Data?) throws {
    guard let fileContents, let text = String(bytes: fileContents, encoding: .utf8) else {
      throw CocoaError(.fileReadCorruptFile)
    }
    self.text = text
  }

  /// The system's type for an extension, or JSON where it has none.
  static func contentType(forExtension fileExtension: String) -> UTType {
    UTType(filenameExtension: fileExtension) ?? .json
  }

  // coverage:off only SwiftUI's save panel can make these; VM flow backlog: export a transcript
  init(configuration: ReadConfiguration) throws {
    try self.init(fileContents: configuration.file.regularFileContents)
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: fileContents)
  }
  // coverage:on
}

extension ConversationContainer {
  /// The `@` menu over the session's workspace: the browsed folder's files and folders, then
  /// deeper paths that contain the typed filter (`src/ma` browses `src` for `ma`).
  static func mentionSearch(_ workspace: WorkspaceBrowserModel)
    -> @MainActor (String) async throws -> [String]
  {
    let source = workspace.source
    return { query in
      let slash = query.lastIndex(of: "/")
      let folder = slash.map { String(query[..<$0]) } ?? ""
      let filter = slash.map { String(query[query.index(after: $0)...]) } ?? query
      do throws(WorkspaceFailure) {
        let listing = try await source.listDirectory(folder, after: nil).entries
        let matches = filter.isEmpty ? [] : try await source.searchPaths(query).entries
        return ComposerStore.mentionRows(
          query: query, listing: listing.map(mentionEntry), matches: matches.map(mentionEntry))
      } catch {
        throw CoreError.InvalidState(message: error.message)
      }
    }
  }

  private static func mentionEntry(_ entry: OmnigentWorkspaceUI.WorkspaceEntry) -> MentionEntry {
    MentionEntry(path: entry.path, name: entry.name, isDirectory: entry.kind == .directory)
  }

  /// The web's link to one message (`?message=<id>`): a user message by its item id, an answer
  /// by its turn. Live previews have no stable id yet.
  static func messageURL(_ row: OmnigentUIComponents.Row, in session: URL?) -> URL? {
    guard let session, !row.isEphemeral,
      var components = URLComponents(url: session, resolvingAgainstBaseURL: false)
    else { return nil }
    let id = row.role == .user ? row.id : (row.responseId ?? row.id)
    components.queryItems =
      (components.queryItems ?? []).filter { $0.name != "message" }
      + [URLQueryItem(name: "message", value: id)]
    return components.url
  }

  /// The session menu's context from the session list: the viewer's projects, the one the
  /// session is in, whether someone else shared it, and the session that created it. A side
  /// chat, which the list leaves out, links to the session it was forked from.
  static func menuContext(
    _ list: SessionListStore, session: OmnigentCoreFFI.SessionSummary?,
    sideChatOf source: String? = nil
  ) -> SessionMenuContext {
    if let source {
      let title = list.sessionWithoutActivity(source)?.title
      return SessionMenuContext(parent: CreatingSession(id: source, title: title))
    }
    guard let session else { return SessionMenuContext() }
    let groups = list.members(of: [session])
    let projects = list.projects.map { project in
      SessionProject(
        id: project.id ?? "label:\(project.name)", name: project.name, sessionIds: [],
        projectID: project.id, icon: project.icon)
    }
    let current = zip(projects, groups).first { $0.1.contains(session.id) }?.0
    let creator = session.createdBySessionId.map {
      CreatingSession(id: $0, title: list.sessionWithoutActivity($0)?.title)
    }
    let parent = list.parent(of: session.id).map {
      CreatingSession(id: $0, title: list.sessionWithoutActivity($0)?.title)
    }
    return SessionMenuContext(
      projects: projects, projectID: current?.id, isShared: !list.isOwned(session),
      createdBy: creator, parent: parent, branch: session.configuration?.gitBranch)
  }
}

extension ConversationContainer {
  /// The session's forkable summary, when this app can fork it.
  var forkSource: OmnigentCoreFFI.SessionSummary? {
    guard makeForkStore != nil, let summary, forkUnavailableReason(source: summary) == nil else {
      return nil
    }
    return summary
  }

  /// "Fork from here" on settled assistant messages; when the session can't be forked it stays,
  /// disabled with the reason, as on the web.
  func forkable(_ actions: ConversationActions) -> ConversationActions {
    var actions = actions
    addRecoveryFork(to: &actions)
    guard makeForkStore != nil, let source = summary else { return actions }
    if let reason = forkUnavailableReason(source: source) {
      actions.forkUnavailableReason = reason
      return actions
    }
    actions.forkFrom = { row in
      guard let responseID = ForkAdapter.forkPoint(row) else { return }
      beginFork(
        ForkContext(source: source, upToResponseID: responseID, kind: .fromMessage(rowID: row.id)))
    }
    return actions
  }

  /// Changes the session's agent, or says why that one isn't available.
  func switchHarness(to agentID: String) {
    let composer = conversation.composer
    if let reason = composer.harnessOptions.first(where: { $0.id == agentID })?.unavailableReason {
      failures.append(reason)
      return
    }
    Task { await composer.switchHarness(to: agentID) }
  }

  /// Forks the whole session (the session menu's Fork, the reconnect sheet's way out); `nil`
  /// when this app cannot fork it.
  var forkSession: (@MainActor () -> Void)? {
    guard let source = forkSource else { return nil }
    let context = ForkContext(source: source, upToResponseID: nil, kind: .session)
    return { beginFork(context) }
  }
}
