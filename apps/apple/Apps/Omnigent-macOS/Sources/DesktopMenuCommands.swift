import OmnigentDesktop
import OmnigentWorkspaceUI
import SwiftUI

/// The desktop menus, with Edit > Find reaching a data table that has the keyboard. The table's
/// focused value is read here rather than in a window's root, so a focus change in the window
/// redraws the menu bar, not the whole window.
struct DesktopMenuCommands: Commands {
  let actions: DesktopCommandActions
  @FocusedValue(\.dataTableFind) private var tableFind

  var body: some Commands {
    OmnigentDesktopCommands(actions: actions, find: tableFind.map(ServerWindowRoot.find))
  }
}
