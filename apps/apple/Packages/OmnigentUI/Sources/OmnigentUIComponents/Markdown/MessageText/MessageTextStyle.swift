#if os(macOS)
  import AppKit
  import OmnigentWorkspaceUI
  import SwiftUI

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
    func font(size base: CGFloat) -> NSFont {
      let points = (base * scale).rounded()
      let weight: NSFont.Weight = isHeavier ? .medium : .regular
      guard !family.isEmpty else { return .monospacedSystemFont(ofSize: points, weight: weight) }
      let descriptor = NSFontDescriptor(fontAttributes: [.family: family])
        .addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue]])
      return NSFont(descriptor: descriptor, size: points)
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

    @MainActor init(environment: EnvironmentValues, code: MessageCodeFont) {
      ramp = environment.typeRamp
      self.code = code
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

  /// A style's fonts and colors as AppKit draws them, resolved once on the main actor so text
  /// can be built off it. Fonts and colors don't change once made.
  nonisolated struct MessageTextPalette: @unchecked Sendable {
    let style: MessageTextStyle
    let text: NSColor
    let secondary: NSColor
    let tertiary: NSColor
    let separator: NSColor
    let link: NSColor
    let codeSurface: NSColor
    let hover: NSColor
    let border: NSColor
    let inlineCodeBackground: NSColor
    /// The code block header's language label (`Theme.Typography.section`).
    let sectionFont: NSFont
    /// Code blocks and raw HTML.
    let codeFont: NSFont
    private let tokenColors: [CodeToken: NSColor]

    @MainActor init(_ style: MessageTextStyle) {
      self.style = style
      let appearance = NSAppearance(named: style.isDark ? .darkAqua : .aqua)
      func system(_ color: NSColor, alpha: CGFloat = 1) -> NSColor {
        var resolved = color
        appearance?.performAsCurrentDrawingAppearance {
          resolved = color.usingColorSpace(.sRGB) ?? color
        }
        return resolved.withAlphaComponent(resolved.alphaComponent * alpha)
      }
      text = system(.labelColor)
      secondary = system(.secondaryLabelColor)
      tertiary = system(.tertiaryLabelColor)
      separator = system(.separatorColor)
      // The parser's inline code fill: `Color.secondary.opacity(0.14)`.
      inlineCodeBackground = system(.secondaryLabelColor, alpha: 0.14)
      link = NSColor(Color(style.link))
      codeSurface = NSColor(Color(style.codeSurface))
      hover = NSColor(Color(style.hover))
      border = NSColor(Color(style.border))
      let caption = NSFont.preferredFont(forTextStyle: .caption1).pointSize
      sectionFont = .systemFont(ofSize: caption, weight: .medium)
      codeFont = style.code.font(size: style.ramp.code)
      let tokens: [CodeToken] =
        [.inserted, .deleted, .header]
        + [SyntaxToken.keyword, .string, .comment, .number, .type].map(CodeToken.syntax)
      tokenColors = Dictionary(
        uniqueKeysWithValues: tokens.map { ($0, Self.color($0, isDark: style.isDark)) })
    }

    /// The prose font at `size`, with `weight`, italic when `italic`.
    func font(size: CGFloat, weight: NSFont.Weight = .regular, italic: Bool = false) -> NSFont {
      let base = NSFont.systemFont(ofSize: size, weight: weight)
      guard italic else { return base }
      let descriptor = base.fontDescriptor.withSymbolicTraits(.italic)
      return NSFont(descriptor: descriptor, size: size) ?? base
    }

    /// Inline code at `size`, semibold inside strong text, as ``TypeRamp/sizingCode(in:size:)``.
    func inlineCode(size: CGFloat, strong: Bool) -> NSFont {
      .monospacedSystemFont(ofSize: size, weight: strong ? .semibold : .regular)
    }

    /// Inline math in its Unicode form, as ``TypeRamp/sizingMath(in:size:)`` sets it.
    func math(size: CGFloat) -> NSFont {
      let base = NSFont.systemFont(ofSize: size)
      let serif = base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
      return NSFont(descriptor: serif.withSymbolicTraits(.italic), size: size) ?? base
    }

    /// A code token's color, as ``CodeHighlighting`` colors it.
    func color(_ token: CodeToken) -> NSColor {
      tokenColors[token] ?? text
    }

    @MainActor private static func color(_ token: CodeToken, isDark dark: Bool) -> NSColor {
      let color: Color =
        switch token {
        case .syntax(let syntax): WorkspaceTheme.tokenColor(syntax, dark ? .dark : .light)
        case .inserted: dark ? StatusColors.diffAdded.dark : StatusColors.diffAdded.light
        case .deleted: dark ? StatusColors.diffRemoved.dark : StatusColors.diffRemoved.light
        case .header: dark ? StatusColors.info.dark : StatusColors.info.light
        }
      return NSColor(color)
    }
  }
#endif
