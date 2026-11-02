import SwiftUI

/// The transcript's type ramp. Every reading size derives from one body size (the platform's
/// prose size, the chat text-size setting and Dynamic Type), and every line height and gap sits
/// on the 4 pt grid.
nonisolated struct TypeRamp: Hashable, Sendable {
  /// Body prose, in points.
  var body: CGFloat

  /// Heading sizes as multiples of the body, H1 to H4; deeper levels use H4.
  static let headingScales: [CGFloat] = [1.4, 1.25, 1.1, 1]
  /// Code, inline and in blocks, as a multiple of the body.
  static let codeScale: CGFloat = 0.9
  /// Body line height as a multiple of its size, before snapping to the grid.
  static let bodyLeading: CGFloat = 1.5
  /// Heading line height as a multiple of its size, before snapping to the grid.
  static let headingLeading: CGFloat = 1.25
  /// The gap between paragraphs and other blocks.
  static let paragraphSpacing: CGFloat = 16
  /// The gap between list items.
  static let listSpacing: CGFloat = 8
  /// The gap above a heading that follows other blocks.
  static let headingAbove: CGFloat = 24
  /// The gap between a heading and its content.
  static let headingBelow: CGFloat = 8
  /// The grid every line height and gap sits on.
  static let grid: CGFloat = 4

  /// The platform's body size before Dynamic Type.
  #if os(macOS)
    static let defaultBody: CGFloat = 15
  #else
    static let defaultBody: CGFloat = 17
  #endif

  /// A heading's size for `level` (1 is the largest), on a half-point.
  func heading(_ level: Int) -> CGFloat {
    let scale = Self.headingScales[min(max(level, 1), Self.headingScales.count) - 1]
    return (body * scale * 2).rounded() / 2
  }

  /// Code size: smaller than prose, so inline code never outgrows its line or a code block.
  var code: CGFloat { (body * Self.codeScale).rounded(.down) }

  /// The body's line height.
  var bodyLineHeight: CGFloat { Self.snapped(body * Self.bodyLeading) }

  /// A heading's line height for `level`.
  func headingLineHeight(_ level: Int) -> CGFloat {
    Self.snapped(heading(level) * Self.headingLeading)
  }

  /// Code's line height.
  var codeLineHeight: CGFloat { Self.snapped(code * Self.bodyLeading) }

  /// The gap above a block, given the block before it (`nil` for the first).
  static func spacing(above block: MarkdownBlock, after previous: MarkdownBlock?) -> CGFloat {
    guard let previous else { return 0 }
    if case .heading = previous { return headingBelow }
    if case .heading = block { return headingAbove }
    return paragraphSpacing
  }

  /// `text` with its inline code spans set in the monospaced face at `size`.
  func sizingCode(in text: AttributedString, size: CGFloat) -> AttributedString {
    var sized = text
    for run in text.runs {
      guard let intent = run.inlinePresentationIntent, intent.contains(.code) else { continue }
      let weight: Font.Weight = intent.contains(.stronglyEmphasized) ? .semibold : .regular
      sized[run.range].swiftUI.font = .system(size: size, weight: weight, design: .monospaced)
    }
    return sized
  }

  /// `value` on the nearest grid line, at least one grid step.
  static func snapped(_ value: CGFloat) -> CGFloat {
    max(grid, (value / grid).rounded() * grid)
  }
}

extension EnvironmentValues {
  /// The reading type ramp for the prose below. Set by ``SwiftUICore/View/readingProseStyle()``.
  @Entry var typeRamp = TypeRamp(body: TypeRamp.defaultBody)
}

/// Editable prose (the composer): the ramp's default body size with the editor's leading.
struct ProseStyle: ViewModifier {
  @ScaledMetric(relativeTo: .body) private var size = TypeRamp.defaultBody
  @ScaledMetric(relativeTo: .body) private var leading = Theme.Typography.leading

  func body(content: Content) -> some View {
    content.font(.system(size: size)).lineSpacing(leading)
  }
}

/// Transcript prose: the ``TypeRamp`` body at the chat text size, on grid line heights.
struct ReadingProseStyle: ViewModifier {
  /// Dynamic Type's scale for body text, as a percentage.
  @ScaledMetric(relativeTo: .body) private var dynamicTypePercent: CGFloat = 100
  @Environment(\.transcriptAppearance) private var appearance

  func body(content: Content) -> some View {
    let ramp = TypeRamp(body: CGFloat(appearance.chatFontSize) * dynamicTypePercent / 100)
    content
      .font(.system(size: ramp.body))
      .lineHeight(.exact(points: ramp.bodyLineHeight))
      .environment(\.typeRamp, ramp)
  }
}

struct ComposerChip: ViewModifier {
  func body(content: Content) -> some View {
    content
      .font(Theme.Typography.label)
      .padding(.horizontal, Theme.Spacing.extraSmall)
      .frame(minWidth: Theme.Control.target, minHeight: Theme.Control.target)
      .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.small))
      .hoverHighlight()
  }
}

extension View {
  /// The transcript, dock and composer share their outside edges: the configured
  /// ``TranscriptContentWidth`` (a reading column by default).
  func readingColumn() -> some View { transcriptColumn() }
  /// Editable prose at the body size (the composer).
  func proseStyle() -> some View { modifier(ProseStyle()) }
  /// Transcript prose from the ``TypeRamp``, which it also publishes for headings and code.
  func readingProseStyle() -> some View { modifier(ReadingProseStyle()) }
  func composerChip() -> some View { modifier(ComposerChip()) }
}
