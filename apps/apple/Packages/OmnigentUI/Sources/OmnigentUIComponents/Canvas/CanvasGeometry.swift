import CoreGraphics

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
      width: CGFloat(maxX - minX) + Self.cardWidth + 2 * Self.margin,
      height: CGFloat(maxY - minY) + Self.cardHeight + 2 * Self.margin)
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

  static func clamp(_ zoom: CGFloat) -> CGFloat {
    min(max(zoom, minZoom), maxZoom)
  }
}
