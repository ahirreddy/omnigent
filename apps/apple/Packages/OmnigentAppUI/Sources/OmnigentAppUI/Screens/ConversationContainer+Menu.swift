import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
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
