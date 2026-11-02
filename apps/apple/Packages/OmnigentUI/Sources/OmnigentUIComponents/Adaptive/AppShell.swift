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
          TabStrip(state: tabs.state, actions: tabs.actions, isInTitlebar: true)
            .frame(width: stripWidth)
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarSpacer(.flexible)
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
  /// the screen's trailing items.
  private var stripWidth: CGFloat {
    let leading = columns == .detailOnly ? TitlebarMetrics.collapsedLeading : 0
    let width = detailWidth - leading - TitlebarMetrics.trailingReserve
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
}

/// Hides the toolbar's title when the selected tab shows it, and backs the toolbar row (the
/// iPhone navigation bar too) with the canvas so scrolled text never shows through it.
private struct TitlelessToolbar: ViewModifier {
  let isActive: Bool

  func body(content: Content) -> some View {
    if isActive {
      #if os(macOS)
        backed(content.toolbar(removing: .title))
      #else
        backed(content.navigationBarTitleDisplayMode(.inline).toolbar(removing: .title))
      #endif
    } else {
      backed(content)
    }
  }

  private func backed(_ content: some View) -> some View {
    content
      .scrollEdgeEffectStyle(.hard, for: .top)
      .overlayPreferenceValue(TitlebarCanvasKey.self) { TitlebarBackdrop(screenCanvas: $0) }
  }
}

/// The theme's canvas behind the toolbar row: the top safe area, which scroll views extend under.
private struct TitlebarBackdrop: View {
  /// The screen's own canvas (CLI style), instead of the theme's.
  let screenCanvas: Color?
  @Environment(\.omnigentTheme) private var theme
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    GeometryReader { proxy in
      VStack(spacing: 0) {
        canvas.frame(height: proxy.safeAreaInsets.top)
        Spacer(minLength: 0)
      }
      .ignoresSafeArea(.container, edges: .top)
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  @ViewBuilder private var canvas: some View {
    if let screenCanvas {
      screenCanvas
    } else if let color = theme.palette(for: colorScheme).canvas {
      color
    } else {
      Rectangle().fill(.background)
    }
  }
}
