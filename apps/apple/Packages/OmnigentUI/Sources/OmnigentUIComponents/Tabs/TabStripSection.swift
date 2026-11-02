import SwiftUI

/// One pane's tabs (or the window's, when it is not split): the pinned ones, then the others,
/// which scroll once they reach their minimum width.
struct TabStripSection<Reorder: Gesture>: View {
  let tabs: [TabItemState]
  /// The tab the pane shows.
  let activeID: String?
  /// The pane has focus, so its tab shows as selected rather than merely shown.
  let isFocused: Bool
  let isSplit: Bool
  let isInTitlebar: Bool
  let actions: TabActions
  let drag: TabDrag?
  let reorder: (TabItemState, [TabItemState], @escaping (TabItemState) -> CGFloat) -> Reorder

  @State private var available: CGFloat = 0
  /// Which ends of the scrolling tabs have tabs out of view, for the fade.
  @State private var overflow = TabOverflow()
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(spacing: Theme.Spacing.extraSmall) {
      let pinned = tabs.filter(\.isPinned)
      if !pinned.isEmpty {
        HStack(spacing: TabMetrics.spacing) {
          ForEach(pinned) { tab in
            item(tab, width: TabMetrics.pinnedWidth, group: pinned) { _ in TabMetrics.pinnedWidth }
          }
        }
        Divider().frame(height: TabMetrics.height - 12)
      }
      unpinnedTabs
    }
  }

  private var unpinned: [TabItemState] { tabs.filter { !$0.isPinned } }

  private var unpinnedTabs: some View {
    let unpinned = unpinned
    let widths = TabStrip.widths(
      available: available, count: unpinned.count,
      includesSelected: unpinned.contains { $0.id == activeID })
    let width: (TabItemState) -> CGFloat = { tab in
      tab.id == activeID ? widths.selected : widths.other
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
      .onChange(of: activeID, initial: true) { _, id in
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

  private func item(
    _ tab: TabItemState, width: CGFloat, group: [TabItemState],
    widthOf: @escaping (TabItemState) -> CGFloat
  ) -> some View {
    let dragged = drag?.id == tab.id ? drag : nil
    let isLast = unpinned.last?.id == tab.id
    let isActive = tab.id == activeID
    return TabItemView(
      tab: tab, isSelected: isActive && isFocused, width: width, actions: actions,
      canCloseToRight: !tab.isPinned && !isLast, isVisibleInOtherPane: isActive && !isFocused,
      isSplit: isSplit
    )
    .offset(x: dragged?.offset ?? 0, y: dragged?.isTearing == true ? dragged?.lift ?? 0 : 0)
    .opacity(dragged?.isTearing == true ? 0.75 : 1)
    .shadow(color: .black.opacity(dragged == nil ? 0 : 0.18), radius: 6, y: 2)
    .zIndex(dragged == nil ? 0 : 1)
    #if os(macOS)
      .gesture(reorder(tab, group, widthOf))
    #endif
  }
}
