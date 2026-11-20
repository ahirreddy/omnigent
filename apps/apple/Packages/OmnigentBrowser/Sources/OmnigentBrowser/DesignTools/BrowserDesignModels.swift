public import CoreGraphics
public import Foundation

/// The Browser design tools: Annotate (pick an element, say what should change) and Draw (mark
/// up the page and send a screenshot).
nonisolated public enum BrowserDesignTool: String, CaseIterable, Hashable, Sendable {
  /// Pick an element and describe a change.
  case annotate
  /// Pen, rectangle, arrow and text marks with a note.
  case draw

  /// The tool's name.
  public var title: String {
    switch self {
    case .annotate: "Annotate"
    case .draw: "Draw"
    }
  }

  /// The tool's SF Symbol.
  public var systemImage: String {
    switch self {
    case .annotate: "cursorarrow.click.2"
    case .draw: "pencil.and.scribble"
    }
  }
}

/// What the element picker reads about one element. Every field is the page's own data.
nonisolated public struct BrowserDesignElement: Hashable, Sendable {
  /// The tag, lowercase.
  public var tag: String
  /// The id with its `#`, or empty.
  public var id: String
  /// Up to four classes, each with its `.`, or empty.
  public var classes: String
  /// The element's text (up to 200 characters), or empty.
  public var text: String
  /// Its `data-testid`, or empty.
  public var testID: String
  /// Its `aria-label`, or empty.
  public var ariaLabel: String
  /// Its `role`, or empty.
  public var role: String

  /// Creates an element.
  public init(
    tag: String = "", id: String = "", classes: String = "", text: String = "",
    testID: String = "", ariaLabel: String = "", role: String = ""
  ) {
    self.tag = tag
    self.id = id
    self.classes = classes
    self.text = text
    self.testID = testID
    self.ariaLabel = ariaLabel
    self.role = role
  }

  /// A short name: the tag and the start of the text, as `p "Your orders…"`.
  public var shortName: String {
    let name = tag.isEmpty ? "element" : tag
    let words = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    guard !words.isEmpty else { return name }
    let clipped = words.count > 28 ? "\(words.prefix(27))\u{2026}" : words
    return "\(name) \"\(clipped)\""
  }
}

/// The element under a point, as the picker answered.
nonisolated public struct BrowserDesignHit: Hashable, Sendable {
  /// The element.
  public var element: BrowserDesignElement
  /// Its bounds in the page's CSS pixels, from the viewport's top left.
  public var rect: CGRect
  /// The page's viewport in CSS pixels (`innerWidth`, `innerHeight`).
  public var viewport: CGSize
  /// The page's key for the element itself, to tell alike ones apart.
  public var key: String

  /// Creates a hit.
  public init(element: BrowserDesignElement, rect: CGRect, viewport: CGSize, key: String) {
    self.element = element
    self.rect = rect
    self.viewport = viewport
    self.key = key
  }

  /// The element's bounds in a view of `size` showing the viewport.
  public func rect(in size: CGSize) -> CGRect {
    guard viewport.width > 0, viewport.height > 0 else { return .zero }
    let scaleX = size.width / viewport.width
    let scaleY = size.height / viewport.height
    return CGRect(
      x: rect.minX * scaleX, y: rect.minY * scaleY, width: rect.width * scaleX,
      height: rect.height * scaleY)
  }
}

/// A Draw mark's shape.
nonisolated public enum BrowserDesignMarkKind: String, CaseIterable, Hashable, Sendable {
  /// A freehand line.
  case pen
  /// A rectangle from one corner to the other.
  case rectangle
  /// An arrow from start to end.
  case arrow
  /// Words at a point.
  case text

  /// The shape's name.
  public var title: String {
    switch self {
    case .pen: "Pen"
    case .rectangle: "Rectangle"
    case .arrow: "Arrow"
    case .text: "Text"
    }
  }

  /// The shape's SF Symbol.
  public var systemImage: String {
    switch self {
    case .pen: "scribble"
    case .rectangle: "rectangle"
    case .arrow: "arrow.up.right"
    case .text: "textformat"
    }
  }
}

/// A mark's color. Fixed rather than themed: marks are drawn into the screenshot.
nonisolated public enum BrowserDesignMarkColor: String, CaseIterable, Hashable, Sendable {
  /// Red.
  case red
  /// Orange.
  case orange
  /// Yellow.
  case yellow
  /// Green.
  case green
  /// Blue.
  case blue
  /// Black.
  case black
  /// White.
  case white

  /// The color's name.
  public var title: String { rawValue.capitalized }

  /// The color as `0xRRGGBB`, the web's palette.
  public var hex: UInt32 {
    switch self {
    case .red: 0xE5484D
    case .orange: 0xF76B15
    case .yellow: 0xFFC53D
    case .green: 0x30A46C
    case .blue: 0x3B8FF5
    case .black: 0x000000
    case .white: 0xFFFFFF
    }
  }

  /// The color for the page's drawing.
  public var cgColor: CGColor {
    let channel = { (shift: UInt32) in Double((hex >> shift) & 0xFF) / 255 }
    return CGColor(srgbRed: channel(16), green: channel(8), blue: channel(0), alpha: 1)
  }
}

/// One Draw mark, in the overlay's points from its top left.
nonisolated public struct BrowserDesignMark: Hashable, Sendable {
  /// The shape.
  public var kind: BrowserDesignMarkKind
  /// A pen's points; a rectangle's or arrow's start and end; a text mark's position.
  public var points: [CGPoint]
  /// The color.
  public var color: BrowserDesignMarkColor
  /// A text mark's words.
  public var text: String

  /// Creates a mark.
  public init(
    kind: BrowserDesignMarkKind, points: [CGPoint], color: BrowserDesignMarkColor,
    text: String = ""
  ) {
    self.kind = kind
    self.points = points
    self.color = color
    self.text = text
  }

  /// The mark drawn on to `point`: a pen adds it, a rectangle or arrow ends there.
  public func extended(to point: CGPoint) -> Self {
    guard let first = points.first, points.last != point else { return self }
    var mark = self
    mark.points = kind == .pen ? points + [point] : [first, point]
    return mark
  }

  /// Whether it went anywhere: a click without a drag draws nothing.
  public var isDrawn: Bool {
    guard let first = points.first else { return false }
    return points.contains { $0 != first }
  }

  /// The mark with each point moved by `move`.
  func mapped(_ move: (CGPoint) -> CGPoint) -> Self {
    var mark = self
    mark.points = points.map(move)
    return mark
  }
}

/// What a tool hands the app to send to the tab's session.
nonisolated public struct BrowserDesignRequest: Hashable, Sendable {
  /// What it asks for.
  public enum Content: Hashable, Sendable {
    /// A picked element and what should change about it.
    case element(BrowserDesignElement, request: String)
    /// A marked-up screenshot and the note, with how many marks it has.
    case drawing(note: String, marks: Int)
  }

  /// What it asks for.
  public var content: Content
  /// The page it was made on.
  public var pageURL: URL?
  /// The screenshot (PNG); `nil` when Annotate's couldn't be taken.
  public var screenshotPNG: Data?

  /// Creates a request.
  public init(content: Content, pageURL: URL?, screenshotPNG: Data?) {
    self.content = content
    self.pageURL = pageURL
    self.screenshotPNG = screenshotPNG
  }

  /// The tool that made it.
  public var tool: BrowserDesignTool {
    if case .element = content { return .annotate }
    return .draw
  }

  /// A one-line name for lists: `Annotate p "Hello"`, or `Draw: the note`.
  public var label: String {
    switch content {
    case .element(let element, _):
      return "Annotate \(element.shortName)"
    case .drawing(let note, let marks):
      let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
      return "Draw: \(trimmed.isEmpty ? (marks == 1 ? "1 mark" : "\(marks) marks") : trimmed)"
    }
  }
}

/// A short message the tools show over the page.
nonisolated public struct BrowserDesignNotice: Hashable, Sendable, Identifiable {
  /// Distinguishes repeats of one message, so each shows its full time.
  public let id: UUID
  /// The words.
  public let message: String
  /// Whether it reports a failure.
  public let isError: Bool

  /// Creates a notice.
  public init(_ message: String, isError: Bool) {
    id = UUID()
    self.message = message
    self.isError = isError
  }
}
