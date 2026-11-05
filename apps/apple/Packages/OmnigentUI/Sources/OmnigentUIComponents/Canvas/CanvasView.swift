public import SwiftUI

/// The Canvas (the web's `/canvas`): every top-level session as a card on a board, one board per
/// project plus Main. Cards can be dragged and snap to the grid; the board pans, zooms and fits
/// itself to its cards until the user zooms by hand.
public struct CanvasView: View {
  private let state: CanvasViewState
  private let actions: CanvasActions
  @State private var zoom: CGFloat = 1
  /// The board follows its cards until the user zooms; Fit and a board switch restore that.
  @State private var followsFit = true
  @State private var pinchStart: CGFloat?
  @State private var dragging: String?
  @State private var dragOffset: CGSize = .zero

  /// Creates the page.
  public init(state: CanvasViewState, actions: CanvasActions) {
    self.state = state
    self.actions = actions
  }

  /// The page.
  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      boardTabs
      if let error = state.refreshError {
        Label("Refresh failed: \(error)", systemImage: "exclamationmark.triangle")
          .font(.callout).foregroundStyle(.secondary)
          .padding(.horizontal, Theme.Spacing.gutter).padding(.bottom, Theme.Spacing.small)
          .accessibilityIdentifier("canvas-refresh-error")
      }
      Divider()
      content
    }
    .themeCanvas()
    .navigationTitle("Canvas")
    .onChange(of: state.activeBoard) { followsFit = true }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.tiny) {
      Text("Canvas").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
      HStack(spacing: Theme.Spacing.small) {
        Text(state.cards.count == 1 ? "1 session" : "\(state.cards.count) sessions")
        if state.isRefreshing {
          ProgressView().controlSize(.mini).accessibilityLabel("Loading sessions")
        }
      }
      .font(.callout).foregroundStyle(.secondary)
      .accessibilityIdentifier("canvas-count")
    }
    .padding(.horizontal, Theme.Spacing.gutter).padding(.top, Theme.Spacing.small)
  }

  private var boardTabs: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: Theme.Spacing.extraSmall) {
        ForEach(state.boards) { board in
          let selected = board.id == state.activeBoard
          Button {
            actions.selectBoard?(board.id)
          } label: {
            HStack(spacing: Theme.Spacing.extraSmall) {
              if let icon = board.icon { Text(icon) }
              Text(board.name).lineLimit(1)
            }
            .padding(.horizontal, Theme.Spacing.medium).padding(.vertical, Theme.Spacing.tiny)
            .frame(maxWidth: 200)
            .foregroundStyle(selected ? .primary : .secondary)
            .background(
              Theme.selection.opacity(selected ? 1 : 0),
              in: RoundedRectangle(cornerRadius: Theme.Radius.small)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.small))
          }
          .buttonStyle(.plain)
          .help(board.name)
          .accessibilityAddTraits(selected ? .isSelected : [])
          .accessibilityIdentifier("canvas-board-\(board.id)")
        }
      }
      .padding(.horizontal, Theme.Spacing.gutter).padding(.vertical, Theme.Spacing.small)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Canvases")
  }

  @ViewBuilder private var content: some View {
    if let error = state.loadError {
      ContentUnavailableView {
        Label("Canvas could not load", systemImage: "exclamationmark.triangle")
      } description: {
        Text(error)
      } actions: {
        if let retry = actions.retry { Button("Retry", action: retry) }
      }
      .accessibilityIdentifier("canvas-load-error")
    } else if state.isLoading {
      ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("Loading Canvas")
    } else {
      surface
    }
  }

  private var surface: some View {
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
      if !state.cards.isEmpty { CanvasDotGrid(origin: geometry.origin) }
      ForEach(state.cards) { card in
        let base = geometry.offset(of: card)
        let moving = dragging == card.id
        CanvasCardView(card: card)
          .offset(
            x: base.width + (moving ? dragOffset.width : 0),
            y: base.height + (moving ? dragOffset.height : 0)
          )
          .zIndex(moving ? 1 : 0)
          .onTapGesture { actions.open?(card.id) }
          .gesture(drag(card))
          .accessibilityElement(children: .combine)
          .accessibilityAddTraits(.isButton)
          .accessibilityAction { actions.open?(card.id) }
          .accessibilityIdentifier("canvas-card-\(card.id)")
      }
    }
  }

  private func drag(_ card: CanvasCard) -> some Gesture {
    DragGesture(minimumDistance: 3)
      .onChanged { value in
        dragging = card.id
        dragOffset = value.translation
      }
      .onEnded { value in
        actions.move?(
          card.id, card.left + Int(value.translation.width.rounded()),
          card.top + Int(value.translation.height.rounded()))
        dragging = nil
        dragOffset = .zero
      }
  }

  private func controls(_ geometry: CanvasGeometry, viewport: CGSize) -> some View {
    VStack(spacing: Theme.Spacing.extraSmall) {
      control("Zoom in", systemImage: "plus.magnifyingglass") {
        followsFit = false
        setZoom(CanvasGeometry.clamp(zoom * CanvasGeometry.zoomStep))
      }
      control("Zoom out", systemImage: "minus.magnifyingglass") {
        followsFit = false
        setZoom(CanvasGeometry.clamp(zoom / CanvasGeometry.zoomStep))
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

  private func setZoom(_ value: CGFloat) {
    if zoom != value { zoom = value }
  }
}

/// The board's dot lattice, aligned to the grid cards snap to.
private struct CanvasDotGrid: View {
  let origin: CGPoint
  /// Past this many dots the lattice is left out; a huge board would redraw too slowly.
  private static let maxDots = 60_000

  var body: some View {
    Canvas { context, size in
      let step = CanvasGeometry.gridStep
      let columns = Int(size.width / step) + 1
      let rows = Int(size.height / step) + 1
      guard columns * rows <= Self.maxDots else { return }
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
