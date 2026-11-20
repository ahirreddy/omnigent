import OmnigentStores
import OmnigentUIComponents
import SwiftUI

// MARK: Extension pages and the window's restored page

extension ConnectedServerView {
  /// Usage, or an extension's page.
  @ViewBuilder func pageOfItsOwn(_ destination: SidebarDestination?) -> some View {
    switch destination {
    case .extensionPage(let extensionID, let route):
      extensionPage(extensionID, route: route)
    default:
      let selection = selectionBinding
      UsageAdapter(connection: connection) { selection.wrappedValue = .session($0) }
    }
  }

  /// An extension's page; its navigation opens the extension's other pages, sessions and New
  /// session in a project.
  func extensionPage(_ extensionID: String, route: String) -> some View {
    let selection = selectionBinding
    let connection = connection
    return ExtensionPageAdapter(
      connection: connection, extensionID: extensionID, route: route,
      show: { selection.wrappedValue = $0 },
      newSession: { project in
        if let project { connection.creation()?.pendingProject = project }
        selection.wrappedValue = .newSession
      }
    )
    .id("\(extensionID)/\(route)")
  }

  /// The window's saved page applies unless the host already chose one (a deep link, a new
  /// window for a session).
  func restore(_ saved: SidebarDestination?) {
    if selectionBinding.wrappedValue == nil, let saved { selectionBinding.wrappedValue = saved }
    session.tabs.show(selectionBinding.wrappedValue)
  }
}
