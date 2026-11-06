#if os(iOS)
  import SwiftUI

  /// Safari's tab overview on iPhone and iPad: the shown tab zooms out into a grid of cards, one
  /// per tab of the shown session, and the chosen card zooms back in. Cards show the picture
  /// ``TabThumbnails`` kept for the tab, never a live tab.
  struct TabGridOverview: View {
    private let state: TabsState
    private let actions: TabActions
    /// Removes the overview without an animation of its own; the zoom has already run.
    private let dismiss: @MainActor () -> Void

    @Namespace private var zoom
    /// The tab drawn over the whole screen: the shown tab as the overview opens, the chosen one
    /// as it closes, and none while the grid shows.
    @State private var zoomedID: String?
    /// The window's width over its height, so a card has the shape of the tab it pictures.
    @State private var aspectRatio: CGFloat = 0.5
    /// The width the grid lays its columns in (``TabGridLayout``).
    @State private var gridWidth: CGFloat = 0
    @State private var isClosing = false

    private static let corner: CGFloat = 16

    init(state: TabsState, actions: TabActions, dismiss: @escaping @MainActor () -> Void) {
      self.state = state
      self.actions = actions
      self.dismiss = dismiss
      _zoomedID = State(initialValue: state.selectedID)
    }

    var body: some View {
      ScrollViewReader { proxy in
        ScrollView {
          LazyVGrid(columns: columns, spacing: 20) {
            ForEach(state.tabs) { tab in card(tab).id(tab.id) }
          }
          .frame(maxWidth: .infinity)
          .padding(.vertical, TabGridLayout.spacing)
        }
        .onAppear {
          if let selected = state.selectedID { proxy.scrollTo(selected, anchor: .center) }
        }
      }
      .background(Color(uiColor: .systemGroupedBackground))
      .safeAreaInset(edge: .bottom) { bottomBar }
      .overlay { zoomedTab }
      .onGeometryChange(for: GridGeometry.self, of: GridGeometry.init) { geometry in
        aspectRatio = geometry.aspectRatio
        gridWidth = geometry.width
      }
      .task {
        withAnimation(.snappy(duration: 0.35)) { zoomedID = nil }
      }
      // A container element, so the cards keep their own identifiers.
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("tab-overview-sheet")
    }

    /// Two columns on iPhone, three or four on iPad, as wide as the window allows.
    private var columns: [GridItem] {
      let item = GridItem(
        .fixed(TabGridLayout.cardWidth(width: gridWidth)), spacing: TabGridLayout.spacing)
      return Array(repeating: item, count: TabGridLayout.columns(width: gridWidth))
    }

    @ViewBuilder private var zoomedTab: some View {
      if let zoomedID, let tab = state.tabs.first(where: { $0.id == zoomedID }) {
        TabThumbnail(tab: tab, cornerRadius: 0)
          .matchedGeometryEffect(id: zoomedID, in: zoom)
          .ignoresSafeArea()
          .accessibilityHidden(true)
      }
    }

    private func card(_ tab: TabItemState) -> some View {
      let isSelected = tab.id == state.selectedID
      return Button {
        open(tab.id)
      } label: {
        VStack(spacing: Theme.Spacing.small) {
          Color.clear
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay {
              if zoomedID != tab.id {
                TabThumbnail(tab: tab, cornerRadius: Self.corner)
                  .matchedGeometryEffect(id: tab.id, in: zoom)
              }
            }
            .overlay {
              RoundedRectangle(cornerRadius: Self.corner)
                .strokeBorder(
                  isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 3)
            }
          HStack(spacing: Theme.Spacing.extraSmall) {
            TabIcon(tab: tab, isSelected: isSelected)
            Text(tab.displayTitle).font(.caption).lineLimit(1)
          }
          .padding(.horizontal, Theme.Spacing.extraSmall)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityValue(isSelected ? "Selected" : "")
      .accessibilityIdentifier("tab-overview-row-\(tab.id)")
      .contextMenu {
        TabContextMenu(
          tab: tab, actions: actions, canCloseToRight: state.unpinned.last?.id != tab.id,
          isSplit: state.split != nil)
      }
      .overlay(alignment: .topTrailing) {
        if tab.isClosable { closeButton(tab) }
      }
    }

    private func closeButton(_ tab: TabItemState) -> some View {
      Button {
        TabThumbnails.shared.remove(tab.id)
        withAnimation(.snappy) { actions.close(tab.id) }
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 11, weight: .bold))
          .frame(width: 24, height: 24)
          .background(.regularMaterial, in: Circle())
          .frame(width: 44, height: 44)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Close \(tab.displayTitle)")
      .accessibilityIdentifier("tab-overview-close-\(tab.id)")
    }

    private var bottomBar: some View {
      HStack {
        Button("New Tab", systemImage: "plus") {
          actions.newTab()
          dismiss()
        }
        .labelStyle(.iconOnly)
        .font(.title3)
        .accessibilityIdentifier("tab-overview-new")
        .contextMenu {
          if let reopen = actions.reopenClosed, !state.recentlyClosed.isEmpty {
            Button("Reopen Closed Tab", systemImage: "arrow.uturn.backward") {
              reopen()
              dismiss()
            }
          }
        }
        Spacer()
        Text(state.tabs.count == 1 ? "1 Tab" : "\(state.tabs.count) Tabs").font(.headline)
        Spacer()
        Button("Done") { open(state.selectedID ?? state.tabs.first?.id) }
          .fontWeight(.semibold)
          .accessibilityIdentifier("tab-overview-done")
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 12)
      .background(.bar)
    }

    /// Shows a tab: its card zooms up to fill the screen, then the overview goes.
    private func open(_ tabID: String?) {
      guard !isClosing else { return }
      isClosing = true
      guard let tabID, state.tabs.contains(where: { $0.id == tabID }) else {
        dismiss()
        return
      }
      if tabID != state.selectedID { actions.select(tabID) }
      withAnimation(.snappy(duration: 0.3)) {
        zoomedID = tabID
      } completion: {
        dismiss()
      }
    }
  }

  /// The grid's width, and the window's shape with its safe areas, as the pictures are taken.
  nonisolated private struct GridGeometry: Equatable {
    var width: CGFloat
    var aspectRatio: CGFloat

    init(_ proxy: GeometryProxy) {
      let insets = proxy.safeAreaInsets
      width = proxy.size.width
      let fullWidth = proxy.size.width + insets.leading + insets.trailing
      aspectRatio = fullWidth / max(proxy.size.height + insets.top + insets.bottom, 1)
    }
  }

  /// A card's picture: the tab as it last looked, or its icon and title on a plain card.
  private struct TabThumbnail: View {
    let tab: TabItemState
    let cornerRadius: CGFloat

    var body: some View {
      ZStack {
        if let image = TabThumbnails.shared.image(for: tab.id) {
          // Filled from the top within the card's own size, which a flexible frame would outgrow.
          Color.clear.overlay(alignment: .top) {
            Image(decorative: image, scale: 1).resizable().scaledToFill()
          }
        } else {
          Rectangle().fill(ThemeColor.surface)
          VStack(spacing: Theme.Spacing.small) {
            Image(systemName: tab.kind.systemImage).font(.largeTitle).accessibilityHidden(true)
            Text(tab.displayTitle).font(.caption).lineLimit(2).multilineTextAlignment(.center)
          }
          .foregroundStyle(.secondary)
          .padding()
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
      .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
    }
  }
#endif
