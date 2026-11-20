import SwiftUI

/// The Canvas's board: the cards on a dotted grid, dragged to move and snapping on drop, with
/// zoom, fit and reset controls. It fits itself to the cards until the user zooms by hand, draws
/// only the cards in view, and on a Mac pans when the empty board is dragged, as the web's.
struct CanvasBoardSurface: View {
  let state: CanvasViewState
  let actions: CanvasActions
  /// A card was clicked, or chosen from the keyboard.
  let select: (String) -> Void
  @State private var zoom: CGFloat = 1
  /// The board follows its cards until the user zooms; Fit and a board switch restore that.
  @State private var followsFit = true
  @State private var pinchStart: CGFloat?
  @State private var dragging: String?
  @State private var dragOffset: CGSize = .zero
  @State private var position = ScrollPosition()
  /// What the scroll view shows, in the zoomed content's coordinates; empty before it lays out.
  @State private var visible: CGRect = .zero
  @State private var panStart: CGPoint?

  var body: some View {
    GeometryReader { proxy in
      let geometry = CanvasGeometry(cards: state.cards)
      ScrollView([.horizontal, .vertical]) {
        board(geometry)
          .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
          .scaleEffect(zoom, anchor: .topLeading)
          .frame(
            width: geometry.size.width * zoom, height: geometry.size.height * zoom,
            alignment: .topLeading
          )
          .frame(minWidth: proxy.size.width, minHeight: proxy.size.height)
      }
      .scrollPosition($position)
      .onScrollGeometryChange(for: CGRect.self) {
        $0.visibleRect
      } action: { _, rect in
        visible = rect
      }
      .simultaneousGesture(
        MagnifyGesture()
          .onChanged { value in
            let start = pinchStart ?? zoom
            pinchStart = start
            followsFit = false
            zoom = CanvasGeometry.clamp(start * value.magnification)
          }
          .onEnded { _ in pinchStart = nil }
      )
      .overlay(alignment: .bottomLeading) { controls(geometry, viewport: proxy.size) }
      .overlay(alignment: .bottomTrailing) { newSessionButton }
      .overlay {
        if state.cards.isEmpty {
          Text(state.emptyTitle).font(.headline).foregroundStyle(.secondary)
            .allowsHitTesting(false)
            .accessibilityIdentifier("canvas-empty")
        }
      }
      .onChange(of: FitKey(cards: cardIDs, viewport: proxy.size, follows: followsFit)) { _, key in
        if key.follows { setZoom(geometry.fitZoom(proxy.size)) }
      }
      .onAppear { if followsFit { setZoom(geometry.fitZoom(proxy.size)) } }
    }
    .onChange(of: state.activeBoard) { followsFit = true }
    // On the board, not the page: the tabs and header keep their own identifiers.
    .accessibilityIdentifier("canvas")
  }

  /// A different card set or viewport refits; moving a card does not.
  private struct FitKey: Equatable {
    let cards: [String]
    let viewport: CGSize
    let follows: Bool
  }

  private var cardIDs: [String] { state.cards.map(\.id) }

  private func board(_ geometry: CanvasGeometry) -> some View {
    ZStack(alignment: .topLeading) {
      panSurface
      if !state.cards.isEmpty { CanvasDotGrid(origin: geometry.origin) }
      ForEach(
        state.cards.filter { card in
          dragging == card.id || geometry.isVisible(card, zoom: zoom, in: visible)
        }
      ) { card in
        cardView(card, geometry: geometry)
      }
    }
  }

  private func cardView(_ card: CanvasCard, geometry: CanvasGeometry) -> some View {
    let base = geometry.offset(of: card)
    let moving = dragging == card.id
    return CanvasCardView(card: card, isSelected: state.quickViewID == card.id)
      .offset(
        x: base.width + (moving ? dragOffset.width : 0),
        y: base.height + (moving ? dragOffset.height : 0)
      )
      .zIndex(moving ? 1 : 0)
      .onTapGesture { select(card.id) }
      .gesture(drag(card))
      .focusable()
      .onKeyPress(keys: [.return, .space]) { _ in
        select(card.id)
        return .handled
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel("\(card.title). \(card.state.label). \(card.workspace)")
      .accessibilityAddTraits(.isButton)
      .accessibilityAddTraits(state.quickViewID == card.id ? .isSelected : [])
      .accessibilityAction { select(card.id) }
      .accessibilityIdentifier("canvas-card-\(card.id)")
  }

  /// Behind the cards: dragging empty board pans it on a Mac, where a scroll view only scrolls
  /// with the wheel; a touch screen's scroll view already pans.
  @ViewBuilder private var panSurface: some View {
    #if os(macOS)
      Color.clear
        .contentShape(Rectangle())
        .gesture(
          DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { value in
              let start = panStart ?? visible.origin
              panStart = start
              position.scrollTo(
                point: CGPoint(
                  x: max(0, start.x - value.translation.width),
                  y: max(0, start.y - value.translation.height)))
            }
            .onEnded { _ in panStart = nil }
        )
    #endif
  }

  private func drag(_ card: CanvasCard) -> some Gesture {
    DragGesture(minimumDistance: 3)
      .onChanged { value in
        dragging = card.id
        dragOffset = value.translation
      }
      .onEnded { value in
        actions.move?(
          card.id, CanvasGeometry.moved(card.left, by: value.translation.width),
          CanvasGeometry.moved(card.top, by: value.translation.height))
        dragging = nil
        dragOffset = .zero
      }
  }

  private func controls(_ geometry: CanvasGeometry, viewport: CGSize) -> some View {
    VStack(spacing: Theme.Spacing.extraSmall) {
      control("Zoom in", systemImage: "plus.magnifyingglass") {
        followsFit = false
        zoomKeepingCenter(CanvasGeometry.clamp(zoom * CanvasGeometry.zoomStep))
      }
      control("Zoom out", systemImage: "minus.magnifyingglass") {
        followsFit = false
        zoomKeepingCenter(CanvasGeometry.clamp(zoom / CanvasGeometry.zoomStep))
      }
      control("Fit view", systemImage: "arrow.up.left.and.arrow.down.right") {
        followsFit = true
        setZoom(geometry.fitZoom(viewport))
      }
      if let reset = actions.resetLayout {
        control("Reset layout", systemImage: "arrow.counterclockwise") {
          followsFit = true
          reset()
        }
      }
    }
    .padding(Theme.Spacing.medium)
  }

  private func control(_ title: String, systemImage: String, action: @escaping () -> Void)
    -> some View
  {
    Button(title, systemImage: systemImage, action: action)
      .labelStyle(.iconOnly)
      .buttonStyle(.bordered)
      .help(title)
      .accessibilityIdentifier(
        "canvas-\(title.lowercased().replacingOccurrences(of: " ", with: "-"))")
  }

  @ViewBuilder private var newSessionButton: some View {
    if let newSession = actions.newSession {
      Button("New session", systemImage: "plus", action: newSession)
        .labelStyle(.iconOnly)
        .font(.title3)
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .tint(Theme.accent)
        .help("New session")
        .padding(Theme.Spacing.large)
        .accessibilityIdentifier("canvas-new-session")
    }
  }

  /// Zooms by the controls around the middle of the view, as the web's do.
  private func zoomKeepingCenter(_ value: CGFloat) {
    let before = zoom
    setZoom(value)
    guard visible.width > 0, before > 0 else { return }
    position.scrollTo(point: CanvasGeometry.scrolled(visible, from: before, to: value))
  }

  private func setZoom(_ value: CGFloat) {
    if zoom != value { zoom = value }
  }
}

/// The board's dot lattice, aligned to the grid cards snap to.
struct CanvasDotGrid: View {
  let origin: CGPoint

  var body: some View {
    Canvas { context, size in
      let step = CanvasGeometry.gridStep
      guard let (columns, rows) = CanvasGeometry.dotLattice(in: size) else { return }
      // The first grid line at or after the content's origin.
      let startX = (origin.x / step).rounded(.up) * step - origin.x
      let startY = (origin.y / step).rounded(.up) * step - origin.y
      var dots = Path()
      for column in 0..<columns {
        for row in 0..<rows {
          let center = CGPoint(
            x: startX + CGFloat(column) * step, y: startY + CGFloat(row) * step)
          dots.addEllipse(in: CGRect(x: center.x - 1, y: center.y - 1, width: 2, height: 2))
        }
      }
      context.fill(dots, with: .color(.secondary.opacity(0.3)))
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}
