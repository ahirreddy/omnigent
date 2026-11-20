public import CoreGraphics
internal import CoreText
internal import Foundation

/// Draws Draw's marks, for the live overlay and the screenshot alike, so what is sent is drawn
/// exactly as it was shown (the web's `drawShape`).
nonisolated public enum BrowserDesignMarkDrawing {
  /// A mark's stroke width, in points.
  static let lineWidth: CGFloat = 3
  /// An arrow head's side, in points, and its angle off the shaft.
  static let arrowHead: CGFloat = 14
  static let arrowAngle: CGFloat = 0.5
  /// A text mark's size, in points.
  static let textSize: CGFloat = 18

  /// Draws `marks` in `context`, whose coordinates are points from the top left (y down).
  /// - Parameters:
  ///   - marks: The marks, oldest first.
  ///   - context: The context.
  public static func draw(_ marks: [BrowserDesignMark], in context: CGContext) {
    for mark in marks { draw(mark, in: context) }
  }

  private static func draw(_ mark: BrowserDesignMark, in context: CGContext) {
    guard let start = mark.points.first else { return }
    let end = mark.points.last ?? start
    if mark.kind == .text {
      drawText(mark.text, color: mark.color, at: start, in: context)
      return
    }
    context.saveGState()
    defer { context.restoreGState() }
    context.setStrokeColor(mark.color.cgColor)
    context.setLineWidth(lineWidth)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.beginPath()
    switch mark.kind {
    case .pen:
      context.addLines(between: mark.points)
    case .rectangle:
      context.addRect(
        CGRect(x: start.x, y: start.y, width: end.x - start.x, height: end.y - start.y))
    case .arrow:
      context.addLines(between: [start, end])
      let angle = atan2(end.y - start.y, end.x - start.x)
      for side: CGFloat in [-1, 1] {
        let barb = CGPoint(
          x: end.x - arrowHead * cos(angle + side * arrowAngle),
          y: end.y - arrowHead * sin(angle + side * arrowAngle))
        context.addLines(between: [end, barb])
      }
    case .text:
      break
    }
    context.strokePath()
  }

  /// Words with a contrasting halo, so they read over any part of the page; `point` is the
  /// middle of their left edge.
  private static func drawText(
    _ text: String, color: BrowserDesignMarkColor, at point: CGPoint, in context: CGContext
  ) {
    guard !text.isEmpty else { return }
    let attributes = [NSAttributedString.Key(kCTFontAttributeName as String): font]
    let line = CTLineCreateWithAttributedString(
      NSAttributedString(string: text, attributes: attributes))
    var ascent: CGFloat = 0
    var descent: CGFloat = 0
    var leading: CGFloat = 0
    _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
    context.saveGState()
    defer { context.restoreGState() }
    // The coordinates run down the page; glyphs are drawn upright.
    context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    context.textPosition = CGPoint(x: point.x, y: point.y + (ascent - descent) / 2)
    let halo: BrowserDesignMarkColor = color == .white ? .black : .white
    context.setLineWidth(4)
    context.setLineJoin(.round)
    context.setStrokeColor(halo.cgColor)
    context.setTextDrawingMode(.stroke)
    CTLineDraw(line, context)
    context.textPosition = CGPoint(x: point.x, y: point.y + (ascent - descent) / 2)
    context.setFillColor(color.cgColor)
    context.setTextDrawingMode(.fill)
    CTLineDraw(line, context)
  }

  /// The system font, semibold (weight 0.3 on Core Text's scale).
  private static var font: CTFont {
    let base =
      CTFontCreateUIFontForLanguage(.system, textSize, nil)
      ?? CTFontCreateWithName("Helvetica" as CFString, textSize, nil)
    let traits = [kCTFontWeightTrait: 0.3] as CFDictionary
    let descriptor = CTFontDescriptorCreateWithAttributes(
      [kCTFontTraitsAttribute: traits] as CFDictionary)
    return CTFontCreateCopyWithAttributes(base, textSize, nil, descriptor)
  }
}
