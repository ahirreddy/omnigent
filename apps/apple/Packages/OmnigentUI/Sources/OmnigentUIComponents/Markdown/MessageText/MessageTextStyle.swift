import OmnigentWorkspaceUI
import SwiftUI

#if canImport(AppKit)
  import AppKit
#else
  import UIKit
#endif

/// The code font Settings › Appearance › Code typography chose, read where SwiftUI tracks it.
nonisolated struct MessageCodeFont: Hashable, Sendable {
  var size: Double
  var family: String
  var isHeavier: Bool
  /// How much larger than the default the code font is.
  var scale: Double

  @MainActor init(_ typography: CodeTypography = .shared) {
    size = typography.size
    family = typography.family
    isHeavier = typography.isHeavier
    scale = typography.scale
  }

  /// The code font for text whose size is `base` at the default setting, as
  /// ``CodeTypography/font(size:)`` makes it.
  func font(size base: CGFloat) -> PlatformFont {
    let points = (base * scale).rounded()
    let weight: PlatformFont.Weight = isHeavier ? .medium : .regular
    guard !family.isEmpty else { return .monospacedSystemFont(ofSize: points, weight: weight) }
    return MessageTextPlatform.font(family: family, size: points, weight: weight)
      ?? .monospacedSystemFont(ofSize: points, weight: weight)
  }
}

/// What a message's text is built with: the type ramp, the code font and the theme's colors,
/// resolved. Equal styles build equal text, so it keys the built text.
nonisolated struct MessageTextStyle: Hashable, Sendable {
  var ramp: TypeRamp
  var code: MessageCodeFont
  var isDark: Bool
  var link: Color.Resolved
  var codeSurface: Color.Resolved
  var hover: Color.Resolved
  var border: Color.Resolved
  /// The display's pixels per point, which SwiftUI rounds a line's baseline to.
  var scale: CGFloat

  /// Whether text in this style looks as in `other`'s, on whatever display: only the scale
  /// differs, as between windows on two displays.
  func hasSameLook(as other: Self) -> Bool {
    var other = other
    other.scale = scale
    return self == other
  }

  @MainActor init(environment: EnvironmentValues, code: MessageCodeFont) {
    ramp = environment.typeRamp
    self.code = code
    scale = environment.displayScale
    isDark = environment.colorScheme == .dark
    func resolved(_ color: ThemeColor) -> Color.Resolved {
      color.resolve(in: environment).resolve(in: environment)
    }
    link = resolved(.link)
    codeSurface = resolved(.codeSurface)
    hover = resolved(.hover)
    border = resolved(.border)
  }
}

/// A style's fonts and colors as the platform's text draws them, resolved once on the main actor
/// so text can be built off it. Fonts and colors don't change once made.
nonisolated struct MessageTextPalette: @unchecked Sendable {
  let style: MessageTextStyle
  let text: PlatformColor
  let secondary: PlatformColor
  let tertiary: PlatformColor
  let separator: PlatformColor
  let link: PlatformColor
  let codeSurface: PlatformColor
  let hover: PlatformColor
  let border: PlatformColor
  let inlineCodeBackground: PlatformColor
  /// The code block header's language label (`Theme.Typography.section`).
  let sectionFont: PlatformFont
  /// Code blocks and raw HTML.
  let codeFont: PlatformFont
  private let tokenColors: [CodeToken: PlatformColor]

  @MainActor init(_ style: MessageTextStyle) {
    self.style = style
    let labels = MessageTextPlatform.labelColors(isDark: style.isDark)
    text = labels.text
    secondary = labels.secondary
    tertiary = labels.tertiary
    separator = labels.separator
    // The parser's inline code fill: `Color.secondary.opacity(0.14)`.
    inlineCodeBackground = labels.secondary.withAlphaComponent(
      labels.secondary.cgColor.alpha * 0.14)
    link = PlatformColor(Color(style.link))
    codeSurface = PlatformColor(Color(style.codeSurface))
    hover = PlatformColor(Color(style.hover))
    border = PlatformColor(Color(style.border))
    sectionFont = .systemFont(ofSize: MessageTextPlatform.captionSize, weight: .medium)
    codeFont = style.code.font(size: style.ramp.code)
    let tokens: [CodeToken] =
      [.inserted, .deleted, .header]
      + [SyntaxToken.keyword, .string, .comment, .number, .type].map(CodeToken.syntax)
    tokenColors = Dictionary(
      uniqueKeysWithValues: tokens.map { ($0, Self.color($0, isDark: style.isDark)) })
  }

  /// The prose font at `size`, with `weight`, italic when `italic`.
  func font(size: CGFloat, weight: PlatformFont.Weight = .regular, italic: Bool = false)
    -> PlatformFont
  {
    let base = PlatformFont.systemFont(ofSize: size, weight: weight)
    return italic ? MessageTextPlatform.italic(base) : base
  }

  /// Inline code at `size`, semibold inside strong text, as ``TypeRamp/sizingCode(in:size:)``.
  func inlineCode(size: CGFloat, strong: Bool) -> PlatformFont {
    .monospacedSystemFont(ofSize: size, weight: strong ? .semibold : .regular)
  }

  /// Inline math in its Unicode form, as ``TypeRamp/sizingMath(in:size:)`` sets it.
  func math(size: CGFloat) -> PlatformFont {
    MessageTextPlatform.serifItalic(size: size)
  }

  /// A code token's color, as ``CodeHighlighting`` colors it.
  func color(_ token: CodeToken) -> PlatformColor {
    tokenColors[token] ?? text
  }

  @MainActor private static func color(_ token: CodeToken, isDark dark: Bool) -> PlatformColor {
    let color: Color =
      switch token {
      case .syntax(let syntax): WorkspaceTheme.tokenColor(syntax, dark ? .dark : .light)
      case .inserted: dark ? StatusColors.diffAdded.dark : StatusColors.diffAdded.light
      case .deleted: dark ? StatusColors.diffRemoved.dark : StatusColors.diffRemoved.light
      case .header: dark ? StatusColors.info.dark : StatusColors.info.light
      }
    return PlatformColor(color)
  }
}
