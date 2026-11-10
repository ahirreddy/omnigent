public import SwiftUI

#if os(macOS)
  import AppKit
#endif

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
  private let sidebar: () -> SidebarViewState
  @Binding private var selection: SidebarDestination?
  private let searchText: () -> Binding<String>
  private let actions: SidebarActions
  private let tabs: (() -> TabStripContent)?
  private let detail: (SidebarDestination?) -> Detail

  @State private var columns: NavigationSplitViewVisibility =
    SidebarLaunchState.current == nil ? .all : .detailOnly
  @State private var stripSpace = TitlebarStripSpace()
  /// A tab dragged from the strip onto the content, for the split view's drop targets.
  @State private var tabDrag = TabDragTracker()
  @Environment(\.horizontalSizeClass) private var sizeClass
  @Environment(\.sidebarToggle) private var sidebarToggle

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
    actions: SidebarActions, tabs: TabStripContent? = nil,
    @ViewBuilder detail: @escaping (SidebarDestination?) -> Detail
  ) {
    self.init(
      sidebar: { sidebar }, selection: selection, searchText: { searchText }, actions: actions,
      tabs: tabs.map { tabs in { tabs } }, detail: detail)
  }

  /// Creates a shell that reads the sidebar and the tabs where it shows them: a change to a
  /// session's row, the search text or a tab's title then renders the sidebar or the strip, not
  /// the window.
  /// - Parameters:
  ///   - sidebar: Sidebar state, read by the sidebar.
  ///   - selection: The selected destination.
  ///   - searchText: Session search, read by the sidebar: making a binding reads its value.
  ///   - actions: Sidebar actions.
  ///   - tabs: The window's tabs and their actions, read by the strip; `nil` shows no tabs.
  ///   - detail: The detail column for a destination.
  public init(
    sidebar: @escaping () -> SidebarViewState, selection: Binding<SidebarDestination?>,
    searchText: @escaping () -> Binding<String>, actions: SidebarActions,
    tabs: (() -> TabStripContent)? = nil,
    @ViewBuilder detail: @escaping (SidebarDestination?) -> Detail
  ) {
    self.sidebar = sidebar
    _selection = selection
    self.searchText = searchText
    self.actions = actions
    self.tabs = tabs
    self.detail = detail
  }

  private var showsStrip: Bool { tabs != nil && sizeClass != .compact }

  /// The shell.
  public var body: some View {
    let columns = settledColumns
    sidebarToggle?.toggle = { columns.wrappedValue = SidebarToggle.toggled(columns.wrappedValue) }
    return NavigationSplitView(columnVisibility: columns) {
      sidebarColumn
        .navigationSplitViewColumnWidth(
          min: AppShellMetrics.sidebarMinWidth, ideal: AppShellMetrics.sidebarIdealWidth,
          max: AppShellMetrics.sidebarMaxWidth
        )
        #if os(iOS)
          // The sidebar has no title (its header names the server), so a large-title bar
          // drew an empty band above it on iPhone.
          .navigationBarTitleDisplayMode(.inline)
        #endif
    } detail: {
      NavigationStack {
        detail(selection)
          .adaptiveLayoutWidth()
          .environment(\.tabsInTitlebar, showsStrip)
          .toolbar { tabsToolbar }
          .modifier(TitlelessToolbar(isActive: showsStrip))
          .onPreferenceChange(TitlebarTrailingItems.self) { [stripSpace] items in
            stripSpace.trailingItems = items
          }
      }
      .unmeasuredMinimum(UnmeasuredMinimum.column)
      // A shown sidebar takes its width from the content (split panes too) on Mac.
      .detailBesideSidebar()
      .environment(tabDrag)
      .onGeometryChange(for: CGFloat.self) {
        $0.size.width
      } action: { width in
        LoopProbe.record("detail width", "\(stripSpace.detailWidth) -> \(width)")
        if stripSpace.detailWidth != width { stripSpace.detailWidth = width }
      }
    }
    .adaptiveLayoutWidth()
    .countsRenders("shell")
    #if os(macOS)
      .modifier(
        SidebarPeekOverlay(
          isCollapsed: columns.wrappedValue == .detailOnly,
          startsShown: SidebarLaunchState.current == .peek
        ) {
          sidebarColumn
        })
    #endif
  }

  /// The sidebar, reading its state in a view of its own.
  private var sidebarColumn: some View {
    ObservationScope("sidebar") {
      SidebarView(
        state: sidebar(), selection: $selection, searchText: searchText(), actions: actions)
    }
  }
}

/// The tab strip's tabs and what they do.
public typealias TabStripContent = (state: TabsState, actions: TabActions)

/// How the sidebar starts, for UI tests and screenshots: `-OmnigentSidebar collapsed` or
/// `-OmnigentSidebar peek` (collapsed, peeking until the pointer moves over the window).
enum SidebarLaunchState: String {
  case collapsed
  case peek

  static let defaultsKey = "OmnigentSidebar"
  static let current = read(.standard)

  /// How the launch arguments in `defaults` ask the sidebar to start.
  static func read(_ defaults: UserDefaults) -> Self? {
    defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:))
  }
}

/// The shell's column sizes.
enum AppShellMetrics {
  static let sidebarMinWidth: CGFloat = 220
  static let sidebarIdealWidth: CGFloat = 248
  static let sidebarMaxWidth: CGFloat = 320
}

extension AppShell {
  /// The sidebar's visibility, with the window laid out on each side of a change on Mac. An
  /// animated change that meets a resize in one layout pass animates the window's root view, and
  /// SwiftUI then resizes the window to that size in every later pass until AppKit throws.
  private var settledColumns: Binding<NavigationSplitViewVisibility> {
    let columns = $columns
    return Binding {
      columns.wrappedValue
    } set: { visibility, transaction in
      Self.layOutVisibleWindows()
      withTransaction(transaction) { columns.wrappedValue = visibility }
      Self.layOutVisibleWindows()
    }
  }

  /// Every window rather than the key one: the toggle's window needn't be key, as when
  /// accessibility presses its button.
  private static func layOutVisibleWindows() {
    #if os(macOS)
      for window in NSApp.windows where window.isVisible {
        window.layoutIfNeeded()
      }
    #endif
  }

  @ToolbarContentBuilder private var tabsToolbar: some ToolbarContent {
    if let tabs {
      if showsStrip {
        ToolbarItem(placement: .navigation) {
          TitlebarTabStrip(
            tabs: tabs, space: stripSpace, isSidebarHidden: columns == .detailOnly)
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarSpacer(.flexible)
        // New Tab sits by the trailing items, not wherever the tabs end.
        ToolbarItem(placement: .primaryAction) {
          ObservationScope("tab controls") {
            let tabs = tabs()
            TabStripControls(state: tabs.state, actions: tabs.actions)
          }
        }
        .sharedBackgroundVisibility(.hidden)
      } else {
        ToolbarItem(placement: Self.switcherPlacement) {
          ObservationScope("tab switcher") {
            let tabs = tabs()
            TabSwitcherButton(state: tabs.state, actions: tabs.actions)
          }
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
}

/// What the titlebar's tab strip is sized from. Only the strip reads it, so resizing the window,
/// animating a column or showing a tab with other toolbar items re-renders the strip instead of
/// the shell and everything it builds.
@MainActor
@Observable
final class TitlebarStripSpace {
  /// The detail column's width.
  var detailWidth: CGFloat = 0
  /// The button widths the shown screen's trailing toolbar items take, if it reports them.
  var trailingItems: Int?
}

/// The tab strip at the width the titlebar has for it.
private struct TitlebarTabStrip: View {
  let tabs: () -> TabStripContent
  let space: TitlebarStripSpace
  let isSidebarHidden: Bool

  var body: some View {
    let tabs = tabs()
    TabStrip(
      state: tabs.state, actions: tabs.actions, isInTitlebar: true, includesControls: false
    )
    .frame(width: stripWidth)
    .countsRenders("strip")
  }

  private var stripWidth: CGFloat {
    TitlebarMetrics.stripWidth(
      detailWidth: space.detailWidth, isSidebarHidden: isSidebarHidden,
      trailingItems: space.trailingItems)
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

  /// Toolbar items take their ideal width, so the strip is given the detail column's width less
  /// what sits around it: the traffic lights and sidebar toggle when the sidebar is hidden, and
  /// the screen's trailing items (as many as it reports, else room for all of them).
  /// - Parameters:
  ///   - detailWidth: The detail column's width.
  ///   - isSidebarHidden: The sidebar is hidden.
  ///   - trailingItems: The screen's trailing button widths, if it reports them.
  /// - Returns: The strip's width.
  static func stripWidth(detailWidth: CGFloat, isSidebarHidden: Bool, trailingItems: Int?)
    -> CGFloat
  {
    let leading = isSidebarHidden ? collapsedLeading : 0
    let trailing = trailingItems.map { trailingWidth(items: $0) } ?? trailingReserve
    let width = detailWidth - leading - trailing - newTabControls
    return max(minimumStrip, width.rounded(.down))
  }

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
    // One view either way: a branch here would build the whole detail again, kept chats
    // included, each time the tabs come or go.
    edged(content.toolbar(removing: isActive ? .title : nil))
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
