public import CoreGraphics
internal import Foundation

/// Where the visible page sits in its document, as the page reads it. Draw keeps its marks in
/// the page's CSS pixels, as the web's do, so they scroll with the page and scale with its zoom.
nonisolated public struct BrowserDesignViewport: Hashable, Sendable {
  /// The visible area's top left, in the document's CSS pixels.
  public var origin: CGPoint
  /// How many CSS pixels the view's width shows: the page's zoom (and a pinch's) as a width.
  public var width: CGFloat

  /// Creates a viewport.
  public init(origin: CGPoint, width: CGFloat) {
    self.origin = origin
    self.width = width
  }

  /// The unscrolled page at 100%, `viewWidth` points wide: the stand-in until the page answers.
  public static func unscrolled(viewWidth: CGFloat) -> Self {
    Self(origin: .zero, width: max(viewWidth, 1))
  }

  /// The page point under `point` in a view `viewWidth` points wide.
  public func pagePoint(_ point: CGPoint, viewWidth: CGFloat) -> CGPoint {
    let factor = viewWidth > 0 ? width / viewWidth : 1
    return CGPoint(x: origin.x + point.x * factor, y: origin.y + point.y * factor)
  }

  /// Where the page point `page` shows in a view `viewWidth` points wide.
  public func viewPoint(_ page: CGPoint, viewWidth: CGFloat) -> CGPoint {
    let factor = width > 0 ? viewWidth / width : 1
    return CGPoint(x: (page.x - origin.x) * factor, y: (page.y - origin.y) * factor)
  }

  /// Maps page CSS pixels into a space `targetWidth` wide over the same visible area, a view's
  /// points or a screenshot's pixels, from its top left.
  public func transform(toWidth targetWidth: CGFloat) -> CGAffineTransform {
    let factor = width > 0 ? targetWidth / width : 1
    return CGAffineTransform(scaleX: factor, y: factor).translatedBy(x: -origin.x, y: -origin.y)
  }

  /// `page` drawn under `old`, moved to show at the same place under this viewport.
  func rebased(_ page: CGPoint, from old: Self) -> CGPoint {
    pagePoint(old.viewPoint(page, viewWidth: 1), viewWidth: 1)
  }

  /// The script answering with the visible area: JSON `{ x, y, width }` in CSS pixels. A pinch
  /// shows the visual viewport, narrower than the layout's.
  static let script = """
    (() => { const v = window.visualViewport; const pinched = !!v && v.scale > 1.001; \
    return JSON.stringify({ x: v ? v.pageLeft : window.scrollX, \
    y: v ? v.pageTop : window.scrollY, width: pinched ? v.width : window.innerWidth }); })()
    """

  /// The script's answer, checked: it is the page's data.
  /// - Throws: `BrowserError.scriptFailed` for an answer that isn't the script's.
  static func viewport(from answer: BrowserScriptValue) throws(BrowserError) -> Self {
    guard let json = answer.stringValue,
      case .object(let fields) = try BrowserScriptValue(jsonData: Data(json.utf8)),
      let left = fields["x"]?.numberValue, let top = fields["y"]?.numberValue,
      let width = fields["width"]?.numberValue, left.isFinite, top.isFinite, width.isFinite,
      width > 0
    else { throw .scriptFailed(message: "The page's scroll position couldn't be read.") }
    return Self(origin: CGPoint(x: left, y: top), width: width)
  }
}
