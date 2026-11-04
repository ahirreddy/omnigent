import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import OmnigentWorkspaceUI
import SwiftUI
import UniformTypeIdentifiers

/// A transcript in the web's `.jsonl` export format, for the save panel.
struct TranscriptExport: FileDocument {
  static let contentType = UTType(filenameExtension: "jsonl") ?? .json
  static var readableContentTypes: [UTType] { [contentType] }

  let text: String

  init(text: String) {
    self.text = text
  }

  init(configuration: ReadConfiguration) throws {
    guard let data = configuration.file.regularFileContents,
      let text = String(bytes: data, encoding: .utf8)
    else {
      throw CocoaError(.fileReadCorruptFile)
    }
    self.text = text
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: Data(text.utf8))
  }
}

extension ConversationContainer {
  /// The `@` menu's search over the session's workspace: files whose path contains the query.
  static func mentionSearch(_ workspace: WorkspaceBrowserModel)
    -> @MainActor (String) async throws -> [String]
  {
    let source = workspace.source
    return { query in
      do throws(WorkspaceFailure) {
        let result = try await source.searchPaths(query)
        return result.entries.filter { $0.kind == .file }.prefix(20).map(\.path)
      } catch {
        throw CoreError.InvalidState(message: error.message)
      }
    }
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
  /// session is in, and whether someone else shared it.
  static func menuContext(_ list: SessionListStore, session: OmnigentCoreFFI.SessionSummary?)
    -> SessionMenuContext
  {
    guard let session else { return SessionMenuContext() }
    let groups = list.members(of: [session])
    let projects = list.projects.map { project in
      SessionProject(
        id: project.id ?? "label:\(project.name)", name: project.name, sessionIds: [],
        projectID: project.id, icon: project.icon)
    }
    let current = zip(projects, groups).first { $0.1.contains(session.id) }?.0
    return SessionMenuContext(
      projects: projects, projectID: current?.id, isShared: !list.isOwned(session))
  }
}
