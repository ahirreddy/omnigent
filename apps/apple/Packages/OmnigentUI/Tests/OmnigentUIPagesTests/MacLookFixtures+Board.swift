import SwiftUI

@testable import OmnigentUIComponents

extension LookFixtures {
  // MARK: Project board

  /// A project board screen, under a window root's appearance so controls take the theme's
  /// accent as they do in the app.
  static func board(_ screen: LookScreen) -> some View {
    var state = PreviewData.boardState
    switch screen {
    case .projectBoardEmpty: state = PreviewData.emptyBoardState
    case .projectBoardQuickView: state.quickViewID = "board_unread"
    case .projectBoardComposer: state.isComposerShown = true
    default: break
    }
    return PreviewData.projectBoard(state) { _ in }
      .omnigentAppearance(.omni)
  }
}
