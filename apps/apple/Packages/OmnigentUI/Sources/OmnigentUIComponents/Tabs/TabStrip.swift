public import SwiftUI

#if os(macOS)
  import AppKit
#endif

/// The window's tab strip: pinned tabs (icon only) on the left, then the other tabs, which
/// shrink to fit and scroll once they reach their minimum width, then New Tab and the tab
/// overview menu.
///
/// In the titlebar (``AppShell`` puts it in the window's toolbar row) it has no bar of its own;
/// its empty space drags the window and a double-click there zooms it, like the titlebar. As a
/// bar of its own it sits above the content.
///
/// A split window's strip has a section per pane, sized like the panes below it, so each tab
/// sits over the pane that shows it.
///
/// On the Mac, drag a tab sideways to reorder it, into the other section to move it to that
/// pane, onto either edge of the content to show it in that pane, and down into the middle of
/// the content to move it to a new window.
public struct TabStrip: View {
  private let state: TabsState
  private let actions: TabActions
  private let isInTitlebar: Bool

  @State private var drag: TabDrag?
  @State private var showsOverview = false
  @State private var sectionsFrame = CGRect.zero
  @State private var sectionFrames: [TabPane: CGRect] = [:]
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(TabDragTracker.self) private var tracker: TabDragTracker?

  /// Creates the strip.
  /// - Parameters:
  ///   - state: The window's tabs.
  ///   - actions: What the tabs do.
  ///   - isInTitlebar: The strip sits in the titlebar row rather than in a bar of its own.
  public init(state: TabsState, actions: TabActions, isInTitlebar: Bool = false) {
    self.state = state
    self.actions = actions
    self.isInTitlebar = isInTitlebar
  }

  /// The strip.
  public var body: some View {
    HStack(spacing: Theme.Spacing.extraSmall) {
      sections
      Button(action: actions.newTab) {
        Image(systemName: "plus")
          .font(.system(size: 13, weight: .medium))
          .frame(width: 26, height: 26)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .hoverHighlight()
      .help("New tab (Command-T)")
      .accessibilityLabel("New tab")
      .accessibilityIdentifier("tab-new")
      .contextMenu { NewTabMenu(actions: actions) }
      TabOverviewMenu(state: state, actions: actions) { showsOverview = true }
      if let issue = state.issue {
        Image(systemName: "exclamationmark.triangle")
          .foregroundStyle(Theme.warning)
          .help(issue)
          .accessibilityLabel(issue)
          .accessibilityIdentifier("tab-issue")
      }
    }
    .padding(.horizontal, isInTitlebar ? 0 : Theme.Spacing.small)
    .frame(height: isInTitlebar ? TabMetrics.height : TabMetrics.stripHeight)
    .frame(maxWidth: .infinity)
    .background { if !isInTitlebar { Rectangle().fill(.bar) } }
    .overlay(alignment: .bottom) { if !isInTitlebar { Divider() } }
    .sheet(isPresented: $showsOverview) {
      TabOverviewSheet(state: state, actions: actions) { showsOverview = false }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Tabs")
    .accessibilityIdentifier("tab-strip")
  }

  /// One section, or one per pane sized like the panes, with a divider between them.
  @ViewBuilder private var sections: some View {
    if let split = state.split {
      let leading = Self.leadingSectionWidth(
        sections: sectionsFrame, dividerX: tracker?.dividerX, fraction: split.fraction)
      HStack(spacing: Theme.Spacing.extraSmall) {
        section(.leading, split: split).frame(width: leading)
        Divider().frame(height: TabMetrics.height - 8)
          .accessibilityHidden(true)
        section(.trailing, split: split)
      }
      .frame(maxWidth: .infinity)
      .onGeometryChange(for: CGRect.self) {
        $0.frame(in: .global)
      } action: {
        sectionsFrame = $0
      }
    } else {
      section(nil, split: nil)
    }
  }

  private func section(_ pane: TabPane?, split: TabSplitState?) -> some View {
    let tabs = pane.map { state.tabs(in: $0) } ?? state.tabs
    let active = pane.flatMap { split?.activeID($0) } ?? state.selectedID
    let isFocused = pane == nil || split?.focused == pane
    return TabStripSection(
      tabs: tabs, activeID: active, isFocused: isFocused, isSplit: split != nil,
      isInTitlebar: isInTitlebar, actions: actions, drag: drag
    ) { tab, group, widthOf in
      reorderGesture(tab, group: group, widthOf: widthOf)
    }
    .onGeometryChange(for: CGRect.self) {
      $0.frame(in: .global)
    } action: { frame in
      if let pane { sectionFrames[pane] = frame }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(pane.map { "\($0.label) pane tabs" } ?? "Tabs")
    .accessibilityIdentifier(pane.map { "tab-section-\($0.rawValue)" } ?? "tab-section")
  }

  /// Widths for `count` unpinned tabs in `available` points: equal shares between the minimum
  /// and maximum width, except that once they shrink the selected tab keeps room for its title
  /// (the titlebar shows no other). Tabs that do not fit at the minimum scroll.
  /// - Parameters:
  ///   - available: The strip's width for unpinned tabs.
  ///   - count: Unpinned tabs.
  ///   - includesSelected: The selected tab is among them.
  /// - Returns: The selected tab's width and every other tab's.
  static func widths(available: CGFloat, count: Int, includesSelected: Bool)
    -> (selected: CGFloat, other: CGFloat)
  {
    guard count > 0, available > 0 else { return (TabMetrics.maxWidth, TabMetrics.maxWidth) }
    let gaps = TabMetrics.spacing * CGFloat(count - 1)
    let even = clamp(((available - gaps) / CGFloat(count)).rounded(.down))
    guard includesSelected, count > 1, even < TabMetrics.selectedWidth else { return (even, even) }
    // The others never go below the minimum: past that the strip scrolls.
    let selected = TabMetrics.selectedWidth
    let other = clamp(((available - gaps - selected) / CGFloat(count - 1)).rounded(.down))
    return (selected, other)
  }

  private static func clamp(_ width: CGFloat) -> CGFloat {
    min(TabMetrics.maxWidth, max(TabMetrics.minWidth, width))
  }

  /// The left section's width: up to the panes' divider when it is under the strip, so each
  /// tab sits over its pane, else the left pane's share.
  /// - Parameters:
  ///   - sections: Both sections' frame, global.
  ///   - dividerX: The panes' divider, global.
  ///   - fraction: The left pane's share.
  /// - Returns: The width.
  static func leadingSectionWidth(sections: CGRect, dividerX: CGFloat?, fraction: Double)
    -> CGFloat
  {
    let minimum = TabMetrics.minWidth
    guard sections.width > minimum * 2 else { return max(0, sections.width / 2) }
    let wanted =
      dividerX.map { $0 - sections.minX - Theme.Spacing.extraSmall }
      ?? sections.width * fraction - Theme.Spacing.extraSmall
    return min(max(wanted, minimum), sections.width - minimum).rounded(.down)
  }

  /// Whether a dragged tab may swap with its neighbour: a session's tabs never pass the primary
  /// chat that leads them.
  /// - Parameters:
  ///   - tab: The dragged tab.
  ///   - neighbour: The tab it would pass.
  ///   - forward: The drag is toward the end of the strip.
  /// - Returns: Whether the swap is allowed.
  static func canSwap(_ tab: TabItemState, with neighbour: TabItemState, forward: Bool) -> Bool {
    guard !forward, neighbour.leadsGroup, !tab.leadsGroup, let group = tab.groupID else {
      return true
    }
    return neighbour.groupID != group
  }

  private func reorderGesture(
    _ tab: TabItemState, group: [TabItemState], widthOf: @escaping (TabItemState) -> CGFloat
  ) -> some Gesture {
    #if os(macOS)
      DragGesture(minimumDistance: 5, coordinateSpace: .global)
        .onChanged { value in dragChanged(value, tab: tab, group: group, widthOf: widthOf) }
        .onEnded { value in dragEnded(value, tab: tab) }
    #else
      // iPad tabs scroll with a swipe; reordering is in the overview.
      DragGesture(minimumDistance: .infinity)
    #endif
  }

  /// Live reorder: the tab swaps with a neighbour once it is dragged past half that
  /// neighbour's width. Below the strip it previews the content's drop targets.
  private func dragChanged(
    _ value: DragGesture.Value, tab: TabItemState, group: [TabItemState],
    widthOf: (TabItemState) -> CGFloat
  ) {
    var current = drag ?? TabDrag(id: tab.id)
    let delta = value.translation.width - current.shift
    let below = value.translation.height > TabDrag.tearDistance
    if !below, let index = group.firstIndex(where: { $0.id == tab.id }) {
      if index + 1 < group.count, Self.canSwap(tab, with: group[index + 1], forward: true),
        case let step = widthOf(group[index + 1]) + TabMetrics.spacing, delta > step / 2
      {
        move(tab.id, besides: group[index + 1].id)
        current.shift += step
      } else if index > 0, Self.canSwap(tab, with: group[index - 1], forward: false),
        case let step = widthOf(group[index - 1]) + TabMetrics.spacing, delta < -step / 2
      {
        move(tab.id, besides: group[index - 1].id)
        current.shift -= step
      }
    }
    current.offset = value.translation.width - current.shift
    current.lift = value.translation.height
    tracker?.update(id: tab.id, pane: tab.pane, location: below ? value.location : nil)
    let dropsInPane = actions.showInPane != nil && tracker?.target != nil
    current.isTearing =
      actions.moveToNewWindow != nil && tab.isClosable && below && !dropsInPane
    drag = current
  }

  /// A release onto a content edge shows the tab in that pane, onto the other section moves it
  /// there, and well below the strip elsewhere moves it to a new window.
  private func dragEnded(_ value: DragGesture.Value, tab: TabItemState) {
    let tearing = drag?.isTearing == true
    let target = tracker?.target
    tracker?.end()
    withAnimation(reduceMotion ? nil : Theme.Motion.feedback) { drag = nil }
    if let showInPane = actions.showInPane {
      if let target {
        showInPane(tab.id, target)
        return
      }
      if state.split != nil, let pane = tab.pane,
        sectionFrames[pane.other]?.contains(value.location) == true
      {
        showInPane(tab.id, pane.other)
        return
      }
    }
    if tearing { actions.moveToNewWindow?(tab.id) }
  }

  private func move(_ id: String, besides neighbour: String) {
    guard let target = state.tabs.firstIndex(where: { $0.id == neighbour }) else { return }
    withAnimation(reduceMotion ? nil : Theme.Motion.feedback) { actions.move(id, target) }
  }
}

/// A tab being dragged.
struct TabDrag: Equatable {
  /// How far below the strip a release tears the tab off.
  static let tearDistance: CGFloat = 56

  let id: String
  /// Horizontal distance already absorbed by swaps with neighbours.
  var shift: CGFloat = 0
  var offset: CGFloat = 0
  var lift: CGFloat = 0
  var isTearing = false
}

#if os(macOS)
  /// What a double-click on the titlebar does, from the user's Desktop & Dock setting.
  enum TitlebarDoubleClick {
    @MainActor static func perform() {
      guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
      switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
      case "Minimize": window.performMiniaturize(nil)
      case "None": break
      default: window.performZoom(nil)
      }
    }
  }
#endif

/// Whether tabs are scrolled out of view at either end.
struct TabOverflow: Equatable {
  var leading = false
  var trailing = false
}

/// A mask that fades the scrolling tabs at an end with tabs out of view, so a clipped tab never
/// meets New Tab with a hard edge.
struct TabOverflowFade: View {
  static let width: CGFloat = 28
  let overflow: TabOverflow

  var body: some View {
    HStack(spacing: 0) {
      if overflow.leading {
        LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
          .frame(width: Self.width)
      }
      Rectangle().fill(.black)
      if overflow.trailing {
        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
          .frame(width: Self.width)
      }
    }
  }
}
