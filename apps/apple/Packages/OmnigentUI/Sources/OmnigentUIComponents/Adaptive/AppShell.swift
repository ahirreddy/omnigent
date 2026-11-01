public import SwiftUI

/// The web's two-column window: the sidebar (navigation, quick filters, sessions) and the detail
/// column for the selected destination, with the right panel as the detail's inspector. On
/// iPhone and a folded Duo it collapses to a stack with the sidebar as the root.
public struct AppShell<Detail: View>: View {
  private let sidebar: SidebarViewState
  @Binding private var selection: SidebarDestination?
  @Binding private var searchText: String
  private let actions: SidebarActions
  private let detail: (SidebarDestination?) -> Detail

  @State private var columns: NavigationSplitViewVisibility = .all

  /// Creates the shell.
  /// - Parameters:
  ///   - sidebar: Sidebar state.
  ///   - selection: The selected destination.
  ///   - searchText: Session search.
  ///   - actions: Sidebar actions.
  ///   - detail: The detail column for a destination.
  public init(
    sidebar: SidebarViewState, selection: Binding<SidebarDestination?>, searchText: Binding<String>,
    actions: SidebarActions, @ViewBuilder detail: @escaping (SidebarDestination?) -> Detail
  ) {
    self.sidebar = sidebar
    _selection = selection
    _searchText = searchText
    self.actions = actions
    self.detail = detail
  }

  /// The shell.
  public var body: some View {
    NavigationSplitView(columnVisibility: $columns) {
      SidebarView(state: sidebar, selection: $selection, searchText: $searchText, actions: actions)
        .navigationSplitViewColumnWidth(min: 220, ideal: 272, max: 360)
    } detail: {
      NavigationStack {
        detail(selection)
          .adaptiveLayoutWidth()
      }
    }
    .adaptiveLayoutWidth()
  }
}
