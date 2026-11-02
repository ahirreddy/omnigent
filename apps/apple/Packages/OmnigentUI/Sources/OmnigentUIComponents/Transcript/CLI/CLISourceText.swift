import Markdown
import SwiftUI

/// The role a span of markdown source plays, for Plain rendering's light tinting.
nonisolated enum SourceTint: UInt8, Hashable, Sendable {
  case none
  case heading
  case bold
  case italic
  case code
  case link
  case fence
}

/// Finds the spans of markdown source to tint, with the same `swift-markdown` parser the rich
/// renderer uses, through its source ranges. The text itself is never changed: Plain shows the
/// agent's output byte for byte.
nonisolated enum SourceTinting {
  struct Span: Hashable, Sendable {
    /// UTF-8 offsets into the source.
    var range: Range<Int>
    var tint: SourceTint
  }

  static func spans(in text: String) -> [Span] {
    guard !text.isEmpty else { return [] }
    let lineStarts = lineStartOffsets(text)
    let document = Document(parsing: text, options: [.disableSmartOpts])
    var spans: [Span] = []
    func offset(_ location: SourceLocation) -> Int? {
      guard location.line >= 1, location.line <= lineStarts.count else { return nil }
      return lineStarts[location.line - 1] + location.column - 1
    }
    func visit(_ markup: any Markup) {
      if let tint = tint(for: markup), let range = markup.range,
        let lower = offset(range.lowerBound), let upper = offset(range.upperBound),
        lower < upper
      {
        spans.append(Span(range: lower..<min(upper, text.utf8.count), tint: tint))
      }
      for child in markup.children { visit(child) }
    }
    visit(document)
    return spans
  }

  private static func tint(for markup: any Markup) -> SourceTint? {
    switch markup {
    case is Heading: .heading
    case is Strong: .bold
    case is Emphasis: .italic
    case is InlineCode: .code
    case is Markdown.Link: .link
    case is CodeBlock: .fence
    default: nil
    }
  }

  private static func lineStartOffsets(_ text: String) -> [Int] {
    var starts = [0]
    var offset = 0
    for byte in text.utf8 {
      offset += 1
      if byte == UInt8(ascii: "\n") { starts.append(offset) }
    }
    return starts
  }

  /// The source with each span's color; later (inner) spans win over the ones around them.
  static func attributed(
    _ text: String, spans: [Span], palette: CLIPalette, cursor: Bool
  ) -> AttributedString {
    let utf8 = text.utf8
    var tints = [SourceTint](repeating: .none, count: utf8.count)
    for span in spans {
      for index in span.range where index < tints.count { tints[index] = span.tint }
    }
    var result = AttributedString()
    var start = 0
    var startIndex = utf8.startIndex
    while start < tints.count {
      var end = start + 1
      while end < tints.count, tints[end] == tints[start] { end += 1 }
      // Span edges come from the parser, so they fall on character boundaries.
      let endIndex = utf8.index(startIndex, offsetBy: end - start)
      var piece = AttributedString(String(text[startIndex..<endIndex]))
      if let color = color(tints[start], palette: palette) { piece.foregroundColor = color }
      if tints[start] == .link { piece.underlineStyle = .single }
      result.append(piece)
      start = end
      startIndex = endIndex
    }
    if cursor { result.append(CLICursor.attributed(palette)) }
    return result
  }

  private static func color(_ tint: SourceTint, palette: CLIPalette) -> Color? {
    switch tint {
    case .none: nil
    case .heading: palette.heading.color
    case .bold: palette.bold.color
    case .italic: palette.italic.color
    case .code: palette.code.color
    case .link: palette.link.color
    case .fence: palette.code.color
    }
  }
}

/// A bounded cache of tint spans, so scrolling re-parses nothing.
@MainActor
final class SourceTintCache {
  static let shared = SourceTintCache(limit: 512)

  private let limit: Int
  private var entries: [String: [SourceTinting.Span]] = [:]
  private var order: [String] = []

  init(limit: Int) {
    self.limit = limit
  }

  func spans(for text: String) -> [SourceTinting.Span] {
    if let cached = entries[text] { return cached }
    let spans = SourceTinting.spans(in: text)
    entries[text] = spans
    order.append(text)
    if order.count > limit {
      entries[order.removeFirst()] = nil
    }
    return spans
  }
}

/// The streaming block cursor.
nonisolated enum CLICursor {
  static let glyph = "\u{2588}"

  static func attributed(_ palette: CLIPalette) -> AttributedString {
    var cursor = AttributedString(glyph)
    cursor.foregroundColor = palette.body.color.opacity(0.75)
    return cursor
  }
}

/// Plain output: the text exactly as emitted, monospaced, whitespace kept, lightly tinted.
struct CLISourceText: View {
  let text: String
  var isStreaming = false
  /// Tint markdown syntax; off for raw tool output.
  var tintsMarkdown = true
  var color: KeyPath<CLIPalette, SRGB> = \.body
  @Environment(\.cliPalette) private var palette

  var body: some View {
    let spans: [SourceTinting.Span] =
      !tintsMarkdown
      ? []
      : isStreaming
        ? SourceTinting.spans(in: text) : SourceTintCache.shared.spans(for: text)
    Text(SourceTinting.attributed(text, spans: spans, palette: palette, cursor: isStreaming))
      .foregroundStyle(palette[keyPath: color].color)
      .cliFont()
      .textSelection(.enabled)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

extension View {
  /// The CLI's monospaced font at the configured size (scaled with Dynamic Type on iOS).
  func cliFont(weight: Font.Weight = .regular) -> some View {
    modifier(CLIFontModifier(weight: weight))
  }
}

private struct CLIFontModifier: ViewModifier {
  let weight: Font.Weight
  @Environment(\.transcriptAppearance) private var appearance
  @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

  func body(content: Content) -> some View {
    let size = appearance.fontSize * scale
    content
      .font(.system(size: size, weight: weight, design: .monospaced))
      .lineSpacing(size * 0.22)
  }
}

/// The CLI font size after Dynamic Type, for metrics that follow the text (marker columns).
struct CLIFontSize: DynamicProperty {
  @Environment(\.transcriptAppearance) private var appearance
  @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

  var points: CGFloat { appearance.fontSize * scale }
  /// One monospaced character's advance.
  var character: CGFloat { points * 0.602 }
  /// One line, with the CLI line spacing.
  var line: CGFloat { points * 1.22 + points * 0.22 }
}
