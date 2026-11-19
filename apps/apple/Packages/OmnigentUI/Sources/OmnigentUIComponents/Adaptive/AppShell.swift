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
  /// Passed to the sidebar and the detail, which show it. The shell's body never reads it: a
  /// view that does runs again each time it changes.
  @Binding private var selection: SidebarDestination?
  private let searchText: () -> Binding<String>
  private let actions: SidebarActions
  private let tabs: ShellTabs?
  private let detail: ShellDetail<Detail>

  /// The sidebar's visibility, which the body never reads: a collapse the split view makes
  /// renders only the strip and the peek, which read ``TitlebarStripSpace/isSidebarHidden``.
  @State private var columns = ShellColumns(SidebarLaunchState.current == nil ? .all : .detailOnly)
  /// Counts the toggles the shell makes itself (``SidebarToggle``), each of which renders it
  /// once, so the split view takes the new visibility.
  @State private var shellToggles = 0
  @State private var stripSpace = TitlebarStripSpace(
    isSidebarHidden: SidebarLaunchState.current != nil)
  /// A tab dragged from the strip onto the content, for the split view's drop targets.
  @State private var tabDrag = TabDragTracker()
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
    self.sidebar = { sidebar }
    _selection = selection
    self.searchText = { searchText }
    self.actions = actions
    self.tabs = tabs.map { tabs in ShellTabs(isShown: { true }, content: { tabs }) }
    self.detail = .selected(detail)
  }

  /// Creates a shell that reads the sidebar, the tabs and the detail where it shows them: a
  /// change to a session's row, the search text, a tab's title or the selection then renders the
  /// sidebar, the strip or the detail, not the window.
  /// - Parameters:
  ///   - sidebar: Sidebar state, read by the sidebar.
  ///   - selection: The selected destination, read by the sidebar.
  ///   - searchText: Session search, read by the sidebar: making a binding reads its value.
  ///   - actions: Sidebar actions.
  ///   - tabs: The window's tabs, read by the titlebar; `nil` shows no tabs.
  ///   - detail: The detail column, which reads what it shows itself.
  public init(
    sidebar: @escaping () -> SidebarViewState, selection: Binding<SidebarDestination?>,
    searchText: @escaping () -> Binding<String>, actions: SidebarActions,
    tabs: ShellTabs? = nil, @ViewBuilder detail: @escaping () -> Detail
  ) {
    self.sidebar = sidebar
    _selection = selection
    self.searchText = searchText
    self.actions = actions
    self.tabs = tabs
    self.detail = .unselected(detail)
  }

  /// The shell.
  public var body: some View {
    _ = shellToggles
    let columns = settledColumns
    let toggles = $shellToggles
    sidebarToggle?.toggle = {
      columns.wrappedValue = SidebarToggle.toggled(columns.wrappedValue)
      // The split view takes the new visibility as the shell renders, laid out at once as the
      // binding's own changes are.
      toggles.wrappedValue += 1
      Self.layOutVisibleWindows()
    }
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
        detailColumn
          // Every page: a transcript, a terminal and a browser all start where the tabs end.
          .belowTitlebar()
          .adaptiveLayoutWidth()
          .modifier(TitlebarTabs(tabs: tabs, space: stripSpace))
          .onPreferenceChange(TitlebarTrailingItems.self) { [stripSpace] items in
            stripSpace.trailingItems = items
          }
      }
      .unmeasuredMinimum(UnmeasuredMinimum.column)
      // A shown sidebar takes its width from the content (split panes too) on Mac.
      .detailBesideSidebar()
      #if os(macOS)
        .sidebarSlide()
      #endif
      .environment(tabDrag)
      .onGeometryChange(for: CGFloat.self) {
        $0.size.width
      } action: { width in
        LoopProbe.record("detail width", "\(stripSpace.detailWidth) -> \(width)")
        if stripSpace.detailWidth != width { stripSpace.detailWidth = width }
      }
    }
    .adaptiveLayoutWidth()
    #if os(macOS)
      .sidebarSlideTransactions()
    #endif
    .countsRenders("shell")
    #if os(macOS)
      .modifier(
        SidebarPeekBesideShell(space: stripSpace, startsShown: SidebarLaunchState.current == .peek)
        {
          sidebarColumn
        })
    #endif
  }

  /// The sidebar, reading its state in a view of its own.
  private var sidebarColumn: some View {
    ObservationScope("sidebar") {
      let state = sidebar()
      SidebarView(state: state, selection: $selection, searchText: searchText(), actions: actions)
        .sessionListCommands(state, actions: actions)
    }
  }

  /// The detail column. Only a detail built for the selection reads it, in a view of its own.
  @ViewBuilder private var detailColumn: some View {
    switch detail {
    case .selected(let detail): SelectedDetail(selection: $selection, detail: detail)
    case .unselected(let detail): detail()
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
    let columns = columns
    let space = stripSpace
    return Binding {
      columns.visibility
    } set: { visibility, transaction in
      Self.layOutVisibleWindows()
      columns.visibility = visibility
      var transaction = transaction
      #if os(macOS)
        if SidebarSlide.holdsAnimations { transaction.disablesAnimations = true }
      #endif
      withTransaction(transaction) { space.isSidebarHidden = visibility == .detailOnly }
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
}

/// What the titlebar's tab strip is sized from. Only the strip reads it, so resizing the window,
/// animating a column or showing a tab with other toolbar items re-renders the strip instead of
/// the shell and everything it builds.
@MainActor
@Observable
final class TitlebarStripSpace {
  /// The detail column's width.
  var detailWidth: CGFloat = 0
  /// Whether the sidebar is hidden, which the strip and the sidebar's peek read.
  var isSidebarHidden: Bool
  /// The button widths the shown screen's trailing toolbar items take, if it reports them.
  var trailingItems: Int?
  /// Counts the times the strip was offered to the toolbar again, as a new item, after the
  /// toolbar left it out. Only the titlebar's items read it.
  var stripOffer = 0
  /// The strip width the last offer was made at, until the toolbar takes the strip.
  @ObservationIgnored var offeredWidth: CGFloat?

  init(isSidebarHidden: Bool = false) {
    self.isSidebarHidden = isSidebarHidden
  }
}

/// The tab strip at the width the titlebar has for it.
struct TitlebarTabStrip: View {
  let tabs: () -> TabStripContent
  let space: TitlebarStripSpace

  var body: some View {
    let tabs = tabs()
    let isSidebarHidden = space.isSidebarHidden
    let stripWidth = TitlebarMetrics.stripWidth(
      detailWidth: space.detailWidth, isSidebarHidden: isSidebarHidden,
      trailingItems: space.trailingItems)
    TabStrip(
      state: tabs.state, actions: tabs.actions, isInTitlebar: true, includesControls: false
    )
    .frame(width: stripWidth)
    #if os(macOS)
      .background {
        TitlebarStripAnchor(space: space, isSidebarHidden: isSidebarHidden, width: stripWidth)
      }
    #endif
    .countsRenders("strip")
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

extension View {
  /// Tells the titlebar's tab strip how many trailing toolbar buttons this tab's page shows while
  /// it is on screen in the focused pane, so the tabs reach them: zero for a page with none.
  /// - Parameter count: Button widths.
  /// - Returns: The view.
  public func titlebarTrailingItems(_ count: Int) -> some View {
    modifier(ShownTabTrailingItems(count: count))
  }
}

/// Hides the toolbar's title when the selected tab shows it. The bars are the system's: Liquid
/// Glass backs their controls (solid under Reduce Transparency, bordered under Increase
/// Contrast). On iOS content scrolls under them; on Mac it stops below them (`belowTitlebar()`),
/// and the soft edge is for a bar pinned in the content, such as the transcript's plan.
struct TitlelessToolbar: ViewModifier {
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
