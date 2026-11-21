import CoreGraphics

/// The board's scroll: where it is, its content and the view, as the scroll view reports them.
nonisolated struct CanvasScroll: Equatable {
  var offset: CGPoint
  var content: CGSize
  var container: CGSize
  /// What shows, in the content's coordinates.
  var visible: CGRect
}

/// The board's drawn area around its cards, and the zoom that fits it in a viewport.
nonisolated struct CanvasGeometry: Equatable {
  static let cardWidth: CGFloat = 280
  static let cardHeight: CGFloat = 132
  static let gridStep: CGFloat = 32
  /// Room around the outermost cards.
  static let margin: CGFloat = 64
  static let minZoom: CGFloat = 0.05
  static let maxZoom: CGFloat = 2.5
  static let zoomStep: CGFloat = 1.25
  /// Past this many dots the lattice is left out; a huge board would redraw too slowly.
  static let maxDots: CGFloat = 60_000

  /// The board point drawn at the content's top-left corner.
  let origin: CGPoint
  /// The content's size at zoom 1.
  let size: CGSize

  init(cards: [CanvasCard]) {
    guard let first = cards.first else {
      origin = CGPoint(x: -Self.margin, y: -Self.margin)
      size = CGSize(width: 2 * Self.margin, height: 2 * Self.margin)
      return
    }
    var minX = first.left
    var minY = first.top
    var maxX = first.left
    var maxY = first.top
    for card in cards {
      minX = min(minX, card.left)
      minY = min(minY, card.top)
      maxX = max(maxX, card.left)
      maxY = max(maxY, card.top)
    }
    origin = CGPoint(x: CGFloat(minX) - Self.margin, y: CGFloat(minY) - Self.margin)
    size = CGSize(
      width: CGFloat(maxX) - CGFloat(minX) + Self.cardWidth + 2 * Self.margin,
      height: CGFloat(maxY) - CGFloat(minY) + Self.cardHeight + 2 * Self.margin)
  }

  /// Where `card` is drawn in the content.
  func offset(of card: CanvasCard) -> CGSize {
    CGSize(width: CGFloat(card.left) - origin.x, height: CGFloat(card.top) - origin.y)
  }

  /// The largest zoom, at most 1, that shows every card in `viewport`.
  func fitZoom(_ viewport: CGSize) -> CGFloat {
    guard viewport.width > 0, viewport.height > 0 else { return 1 }
    let fit = min(viewport.width / size.width, viewport.height / size.height, 1)
    return Self.clamp(fit)
  }

  /// Room around the view inside which cards are drawn, so a scroll shows them at once.
  static let drawMargin: CGFloat = 400

  /// Whether `card` is in or near `visible`, the scroll view's rectangle in the zoomed
  /// content; before the scroll view reports one, every card is.
  func isVisible(_ card: CanvasCard, zoom: CGFloat, in visible: CGRect) -> Bool {
    guard visible.width > 0, visible.height > 0 else { return true }
    let offset = offset(of: card)
    let frame = CGRect(
      x: offset.width * zoom, y: offset.height * zoom, width: Self.cardWidth * zoom,
      height: Self.cardHeight * zoom)
    return frame.intersects(visible.insetBy(dx: -Self.drawMargin, dy: -Self.drawMargin))
  }

  /// Where to scroll so the middle of `visible` stays put as the zoom goes from `old` to `new`.
  static func scrolled(_ visible: CGRect, from old: CGFloat, to new: CGFloat) -> CGPoint {
    let scale = old > 0 ? new / old : 1
    return CGPoint(
      x: max(0, visible.midX * scale - visible.width / 2),
      y: max(0, visible.midY * scale - visible.height / 2))
  }

  static func clamp(_ zoom: CGFloat) -> CGFloat {
    min(max(zoom, minZoom), maxZoom)
  }

  /// Where to scroll so the middle of the view stays put as it goes from `old` to `new`, from
  /// `origin`, the scroll view's top-left corner, which a resize leaves in place.
  static func recentered(_ origin: CGPoint, from old: CGSize, to new: CGSize) -> CGPoint {
    CGPoint(
      x: max(0, origin.x - (new.width - old.width) / 2),
      y: max(0, origin.y - (new.height - old.height) / 2))
  }

  /// Whether the board scrolled from `old` to `new` by a wheel, trackpad or touch rather than by
  /// its own layout: the same content and view, and an offset that moved for more than a clamp
  /// into a smaller range.
  static func isUserScroll(from old: CanvasScroll, to new: CanvasScroll) -> Bool {
    guard old.content == new.content, old.container == new.container else { return false }
    let maxX = max(0, new.content.width - new.container.width)
    let maxY = max(0, new.content.height - new.container.height)
    let clamped = CGPoint(
      x: min(max(old.offset.x, 0), maxX), y: min(max(old.offset.y, 0), maxY))
    return abs(clamped.x - new.offset.x) > 0.5 || abs(clamped.y - new.offset.y) > 0.5
  }

  /// The furthest a saved coordinate goes, as the core's bound.
  static let maxCoordinate = 1_000_000

  /// The grid coordinate a card at `position` lands on after a drag by `translation`: the
  /// nearest grid line, halves rounding up, within the saved bound, as the core's snap.
  static func snapped(_ position: Int, by translation: CGFloat) -> Int {
    let bounded = min(max(moved(position, by: translation), -maxCoordinate), maxCoordinate)
    let step = Int(gridStep)
    return Int((Double(bounded) / Double(step) + 0.5).rounded(.down)) * step
  }

  /// How far a dragged card is drawn from its spot: at the grid point it would land on, so it
  /// snaps as it moves, as the web's.
  static func snappedOffset(left: Int, top: Int, by translation: CGSize) -> CGSize {
    CGSize(
      width: CGFloat(snapped(left, by: translation.width)) - CGFloat(left),
      height: CGFloat(snapped(top, by: translation.height)) - CGFloat(top))
  }

  /// A card's coordinate after a drag; a stored position at the limit of `Int` stays there.
  static func moved(_ position: Int, by translation: CGFloat) -> Int {
    guard translation.isFinite else { return position }
    let distance = Int(exactly: translation.rounded()) ?? (translation < 0 ? .min : .max)
    let (sum, overflowed) = position.addingReportingOverflow(distance)
    guard overflowed else { return sum }
    return distance < 0 ? .min : .max
  }

  /// How many dots fill `size`, or `nil` when there are too many to draw.
  static func dotLattice(in size: CGSize) -> (columns: Int, rows: Int)? {
    let columns = (size.width / gridStep).rounded(.down) + 1
    let rows = (size.height / gridStep).rounded(.down) + 1
    guard columns >= 1, rows >= 1, columns * rows <= maxDots else { return nil }
    return (Int(columns), Int(rows))
  }
}
