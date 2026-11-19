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

  /// A session's chat in a board's quick view, once its conversation is open.
  @ViewBuilder private func quickViewChat(_ id: String) -> some View {
    if let chat = chat(id) {
      chat.id(id)
    } else {
      LoadingCaption(title: "Opening the session\u{2026}")
    }
  }
}
