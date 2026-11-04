public import SwiftUI

/// The web's two-column window: the sidebar (navigation, quick filters, sessions) and the detail
/// column for the selected destination, with the right panel as the detail's inspector. On
/// iPhone and a folded Duo it collapses to a stack with the sidebar as the root.
///
/// With tabs, the tab strip sits in the detail column's titlebar row where there is room (Mac,
/// iPad at regular width), like Safari's compact tabs: the sidebar toggle, the tabs (which take
/// the free width), New Tab and the overview menu, then the screen's compact trailing items. The
/// selected tab carries the title and status, so the toolbar shows no title. Compact widths show
/// a Tabs button that opens the tab overview, and the detail shows the selected tab.
public struct AppShell<Detail: View>: View {
  private let sidebar: SidebarViewState
  @Binding private var selection: SidebarDestination?
  @Binding private var searchText: String
  private let actions: SidebarActions
  private let tabs: (state: TabsState, actions: TabActions)?
  private let detail: (SidebarDestination?) -> Detail

  @State private var columns: NavigationSplitViewVisibility = .all
  @State private var detailWidth: CGFloat = 0
  @State private var trailingItems: Int?
  /// A tab dragged from the strip onto the content, for the split view's drop targets.
  @State private var tabDrag = TabDragTracker()
  @Environment(\.horizontalSizeClass) private var sizeClass

  /// Creates the shell.
  /// - Parameters:
  ///   - sidebar: Sidebar state.
  ///   - selection: The selected destination.
  ///   - searchText: Session search.
  ///   - actions: Sidebar actions.
  ///   - tabs: The window's tabs and their actions; `nil` shows the detail without tabs.
  ///   - detail: The detail column for a destination.
  public init(
    sidebar: SidebarViewState, selection: Binding<SidebarDestination?>, searchText: Binding<String>,
    actions: SidebarActions, tabs: (state: TabsState, actions: TabActions)? = nil,
    @ViewBuilder detail: @escaping (SidebarDestination?) -> Detail
  ) {
    self.sidebar = sidebar
    _selection = selection
    _searchText = searchText
    self.actions = actions
    self.tabs = tabs
    self.detail = detail
  }

  private var showsStrip: Bool { tabs != nil && sizeClass != .compact }

  /// The shell.
  public var body: some View {
    NavigationSplitView(columnVisibility: $columns) {
      SidebarView(state: sidebar, selection: $selection, searchText: $searchText, actions: actions)
        .navigationSplitViewColumnWidth(min: 220, ideal: 248, max: 320)
    } detail: {
      NavigationStack {
        detail(selection)
          .adaptiveLayoutWidth()
          .environment(\.tabsInTitlebar, showsStrip)
          .toolbar { tabsToolbar }
          .modifier(TitlelessToolbar(isActive: showsStrip))
          .onPreferenceChange(TitlebarTrailingItems.self) { trailingItems = $0 }
      }
      .environment(tabDrag)
      .onGeometryChange(for: CGFloat.self) {
        $0.size.width
      } action: {
        detailWidth = $0
      }
    }
    .adaptiveLayoutWidth()
  }
}

extension AppShell {
  @ToolbarContentBuilder private var tabsToolbar: some ToolbarContent {
    if let tabs {
      if showsStrip {
        ToolbarItem(placement: .navigation) {
          TabStrip(
            state: tabs.state, actions: tabs.actions, isInTitlebar: true, includesControls: false
          )
          .frame(width: stripWidth)
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarSpacer(.flexible)
        // New Tab sits by the trailing items, not wherever the tabs end.
        ToolbarItem(placement: .primaryAction) {
          TabStripControls(state: tabs.state, actions: tabs.actions)
        }
        .sharedBackgroundVisibility(.hidden)
      } else {
        ToolbarItem(placement: Self.switcherPlacement) {
          TabSwitcherButton(state: tabs.state, actions: tabs.actions)
        }
      }
    }
  }

  /// Compact widths: beside the back button, where the bar never folds it into its overflow.
  private static var switcherPlacement: ToolbarItemPlacement {
    #if os(iOS)
      .topBarLeading
    #else
      .automatic
    #endif
  }

  /// Toolbar items take their ideal width, so the strip is given the detail column's width less
  /// what sits around it: the traffic lights and sidebar toggle when the sidebar is hidden, and
  /// the screen's trailing items (as many as it reports, else room for all of them).
  private var stripWidth: CGFloat {
    let leading = columns == .detailOnly ? TitlebarMetrics.collapsedLeading : 0
    let trailing =
      trailingItems.map { TitlebarMetrics.trailingWidth(items: $0) }
      ?? TitlebarMetrics.trailingReserve
    let width = detailWidth - leading - trailing - TitlebarMetrics.newTabControls
    return max(TitlebarMetrics.minimumStrip, width.rounded(.down))
  }
}

/// Room around the tab strip in the titlebar row.
enum TitlebarMetrics {
  #if os(macOS)
    /// Traffic lights and the sidebar toggle, when the sidebar is hidden.
    static let collapsedLeading: CGFloat = 150
    /// The trailing cluster (viewers, Info, the session menu, the right-panel toggle) and the
    /// toolbar's own margins.
    static let trailingReserve: CGFloat = 236
  #else
    static let collapsedLeading: CGFloat = 64
    /// The navigation bar's trailing group needs more room than the Mac toolbar's.
    static let trailingReserve: CGFloat = 300
  #endif
  /// The strip never gets narrower than this; the toolbar then moves trailing items to its
  /// overflow menu.
  static let minimumStrip: CGFloat = 220
  /// New Tab and the overview menu, beside the trailing items.
  static let newTabControls: CGFloat = 64

  /// Room for `items` trailing toolbar buttons and the toolbar's margins.
  /// - Parameter items: Button widths (a viewer stack counts as two).
  /// - Returns: The width to keep clear of the strip.
  static func trailingWidth(items: Int) -> CGFloat {
    #if os(macOS)
      32 + 36 * CGFloat(items)
    #else
      trailingReserve
    #endif
  }
}

/// How many button widths the detail's trailing toolbar items take, so the titlebar's tab strip
/// reaches them instead of stopping short. `nil` when the detail does not say.
struct TitlebarTrailingItems: PreferenceKey {
  static let defaultValue: Int? = nil

  static func reduce(value: inout Int?, nextValue: () -> Int?) {
    value = nextValue() ?? value
  }
}

/// Hides the toolbar's title when the selected tab shows it. The bars are the system's: content
/// scrolls under them with the soft scroll edge effect, and Liquid Glass backs their controls
/// (solid under Reduce Transparency, bordered under Increase Contrast).
private struct TitlelessToolbar: ViewModifier {
  let isActive: Bool

  func body(content: Content) -> some View {
    if isActive {
      edged(content.toolbar(removing: .title))
    } else {
      edged(content)
    }
  }

  private func edged(_ content: some View) -> some View {
    #if os(iOS)
      // Inline titles: the large-title band above a short transcript drew empty.
      content.navigationBarTitleDisplayMode(.inline)
    #else
      content.scrollEdgeEffectStyle(.soft, for: .top)
    #endif
  }
}
