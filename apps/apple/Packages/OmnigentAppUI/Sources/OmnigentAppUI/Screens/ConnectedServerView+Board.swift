import OmnigentPlatform
import OmnigentUIComponents
import SwiftUI

// MARK: Project boards

extension ConnectedServerView {
  /// A project's board, keyed by its folder so each project starts unfiltered with its composer
  /// closed.
  func projectBoard(_ folderID: String) -> some View {
    ProjectBoardContainer(
      session: session, folderID: folderID, sidebarActions: sidebarActions,
      details: sidebarModel.display.details, open: { selectionBinding.wrappedValue = .session($0) },
      newSession: { newSession(in: $0) }, chat: { AnyView(quickViewChat($0)) }
    )
    .id(folderID)
  }

  /// The Canvas: a card's session opens beside the board, and New session starts in the
  /// board's project.
  var canvasPage: some View {
    CanvasAdapter(
      connection: connection, open: { selectionBinding.wrappedValue = .session($0) },
      newSession: { project in
        if let project {
          newSession(in: project)
        } else {
          selectionBinding.wrappedValue = .newSession
        }
      },
      tabs: session.tabs, chat: { AnyView(quickViewChat($0)) }, projectActions: sidebarActions)
  }

  /// A session's chat in a board's or the Canvas's quick view, once its conversation is open.
  @ViewBuilder func quickViewChat(_ id: String) -> some View {
    if let chat = chat(id) {
      chat.id(id)
    } else {
      LoadingCaption(title: "Opening the session\u{2026}")
    }
  }
}
