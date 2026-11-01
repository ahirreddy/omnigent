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
/// On the Mac, drag a tab sideways to reorder it and drag it down out of the strip to move it
/// to a new window.
public struct TabStrip: View {
  private let state: TabsState
  private let actions: TabActions
  private let isInTitlebar: Bool

  @State private var available: CGFloat = 0
  /// Which ends of the scrolling tabs have tabs out of view, for the fade.
  @State private var overflow = TabOverflow()
  @State private var drag: TabDrag?
  @State private var showsOverview = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
      let pinned = state.pinned
      if !pinned.isEmpty {
        HStack(spacing: TabMetrics.spacing) {
          ForEach(pinned) { tab in
            item(tab, width: TabMetrics.pinnedWidth, group: pinned) { _ in TabMetrics.pinnedWidth }
          }
        }
        Divider().frame(height: TabMetrics.height - 12)
      }
      unpinnedTabs
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

  private var unpinnedTabs: some View {
    let unpinned = state.unpinned
    let widths = Self.widths(
      available: available, count: unpinned.count,
      includesSelected: unpinned.contains { $0.id == state.selectedID })
    let width: (TabItemState) -> CGFloat = { tab in
      tab.id == state.selectedID ? widths.selected : widths.other
    }
    return ScrollViewReader { proxy in
      ScrollView(.horizontal) {
        HStack(spacing: TabMetrics.spacing) {
          ForEach(unpinned) { tab in
            item(tab, width: width(tab), group: unpinned, widthOf: width).id(tab.id)
          }
        }
        .frame(minWidth: available, alignment: .leading)
        .background { emptyStrip }
      }
      .scrollIndicators(.never)
      .onScrollGeometryChange(for: TabOverflow.self) { geometry in
        TabOverflow(
          leading: geometry.contentOffset.x > 1,
          trailing: geometry.contentOffset.x + geometry.containerSize.width
            < geometry.contentSize.width - 1)
      } action: { _, edges in
        overflow = edges
      }
      .mask { TabOverflowFade(overflow: overflow) }
      .onChange(of: state.selectedID, initial: true) { _, id in
        guard let id, unpinned.contains(where: { $0.id == id }) else { return }
        withAnimation(reduceMotion ? nil : Theme.Motion.feedback) { proxy.scrollTo(id) }
      }
    }
    .frame(maxWidth: .infinity)
    .onGeometryChange(for: CGFloat.self) {
      $0.size.width
    } action: {
      available = $0
    }
    .padding(.trailing, Theme.Spacing.extraSmall)
  }

  /// The strip's empty space. In the titlebar it behaves like the titlebar: it drags the window
  /// and a double-click zooms it. In a bar of its own a double-click opens a new tab.
  @ViewBuilder private var emptyStrip: some View {
    let space = Color.clear.contentShape(Rectangle())
    #if os(macOS)
      if isInTitlebar {
        space
          .onTapGesture(count: 2) { TitlebarDoubleClick.perform() }
          .gesture(WindowDragGesture())
          .allowsWindowActivationEvents(true)
          .accessibilityHidden(true)
      } else {
        space.onTapGesture(count: 2) { actions.newTab() }
      }
    #else
      space.onTapGesture(count: 2) { actions.newTab() }
    #endif
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

  private func item(
    _ tab: TabItemState, width: CGFloat, group: [TabItemState],
    widthOf: @escaping (TabItemState) -> CGFloat
  ) -> some View {
    let dragged = drag?.id == tab.id ? drag : nil
    let isLast = state.unpinned.last?.id == tab.id
    return TabItemView(
      tab: tab, isSelected: tab.id == state.selectedID, width: width, actions: actions,
      canCloseToRight: !tab.isPinned && !isLast
    )
    .offset(x: dragged?.offset ?? 0, y: dragged?.isTearing == true ? dragged?.lift ?? 0 : 0)
    .opacity(dragged?.isTearing == true ? 0.75 : 1)
    .shadow(color: .black.opacity(dragged == nil ? 0 : 0.18), radius: 6, y: 2)
    .zIndex(dragged == nil ? 0 : 1)
    #if os(macOS)
      .gesture(reorderGesture(tab, group: group, widthOf: widthOf))
    #endif
  }

  #if os(macOS)
    /// Live reorder: the tab swaps with a neighbour once it is dragged past half that
    /// neighbour's width. Released well below the strip, it moves to a new window.
    private func reorderGesture(
      _ tab: TabItemState, group: [TabItemState], widthOf: @escaping (TabItemState) -> CGFloat
    ) -> some Gesture {
      DragGesture(minimumDistance: 5, coordinateSpace: .global)
        .onChanged { value in
          var current = drag ?? TabDrag(id: tab.id)
          let delta = value.translation.width - current.shift
          if let index = group.firstIndex(where: { $0.id == tab.id }) {
            if index + 1 < group.count,
              case let step = widthOf(group[index + 1]) + TabMetrics.spacing, delta > step / 2
            {
              move(tab.id, besides: group[index + 1].id)
              current.shift += step
            } else if index > 0,
              case let step = widthOf(group[index - 1]) + TabMetrics.spacing, delta < -step / 2
            {
              move(tab.id, besides: group[index - 1].id)
              current.shift -= step
            }
          }
          current.offset = value.translation.width - current.shift
          current.lift = value.translation.height
          current.isTearing =
            actions.moveToNewWindow != nil && value.translation.height > TabDrag.tearDistance
          drag = current
        }
        .onEnded { _ in
          let tearing = drag?.isTearing == true
          withAnimation(reduceMotion ? nil : Theme.Motion.feedback) { drag = nil }
          if tearing { actions.moveToNewWindow?(tab.id) }
        }
    }
  #endif

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
private struct TabOverflowFade: View {
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
