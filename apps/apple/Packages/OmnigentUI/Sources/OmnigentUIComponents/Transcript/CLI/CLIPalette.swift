public import SwiftUI

/// A theme's terminal colors: the background, foreground and accent slots a terminal theme
/// defines. The CLI roles map onto these slots, as terminal UIs map onto ANSI colors.
nonisolated struct TerminalScheme: Hashable, Sendable {
  var background: SRGB
  /// The default text color.
  var foreground: SRGB
  /// Metadata and markers (a terminal's "bright black").
  var dim: SRGB
  /// Headings (orange or yellow).
  var heading: SRGB
  /// Bold and italic (magenta or pink).
  var emphasis: SRGB
  /// Inline code (green).
  var code: SRGB
  /// Links (blue).
  var link: SRGB
  /// Paths and tool subjects (a deeper blue).
  var path: SRGB
  /// Block quotes (a light violet).
  var quote: SRGB
  /// Table headers and third-level headings (a light yellow).
  var strong: SRGB
  /// List markers (cyan).
  var marker: SRGB
  /// Failure (red).
  var failure: SRGB

  init(
    _ background: UInt32, _ foreground: UInt32, dim: UInt32, heading: UInt32, emphasis: UInt32,
    code: UInt32, link: UInt32, path: UInt32, quote: UInt32, strong: UInt32, marker: UInt32,
    failure: UInt32, isDisplayP3: Bool = false
  ) {
    func color(_ hex: UInt32) -> SRGB { SRGB(hex: hex, isDisplayP3: isDisplayP3) }
    self.background = color(background)
    self.foreground = color(foreground)
    self.dim = color(dim)
    self.heading = color(heading)
    self.emphasis = color(emphasis)
    self.code = color(code)
    self.link = color(link)
    self.path = color(path)
    self.quote = color(quote)
    self.strong = color(strong)
    self.marker = color(marker)
    self.failure = color(failure)
  }

  /// The terminal scheme for a theme and scheme. Built-in palettes use their own terminal
  /// colors (Nord matches the reference Codex screenshots); Custom starts from its base preset
  /// and takes its background, accent and link.
  static func scheme(for theme: OmnigentTheme, dark: Bool) -> Self {
    if theme.id == "custom" {
      let palette = dark ? theme.dark : theme.light
      let base = scheme(id: customBase(theme), dark: dark)
      var scheme = base
      scheme.background = palette.canvas.map(SRGB.init) ?? (dark ? base.background : .white)
      scheme.emphasis = SRGB(palette.accent)
      scheme.link = SRGB(palette.link)
      return scheme
    }
    return scheme(id: theme.id, dark: dark)
  }

  /// Custom themes carry their base preset's link; find the preset that matches.
  private static func customBase(_ theme: OmnigentTheme) -> String {
    OmnigentTheme.builtIn.first {
      $0.dark.link == theme.dark.link && $0.light.link == theme.light.link
    }?.id ?? OmnigentTheme.omni.id
  }

  // The slot tables are data; one entry per palette and scheme.
  // swiftlint:disable:next function_body_length cyclomatic_complexity
  private static func scheme(id: String, dark: Bool) -> Self {
    switch (id, dark) {
    case ("nord", true):
      // Measured from the reference Codex CLI screenshots, which are Display P3.
      Self(
        0x0E2A35, 0x869496, dim: 0x616B6D, heading: 0xEFB68E, emphasis: 0xE590A8,
        code: 0xB3E1A7, link: 0x92B3F4, path: 0x73A6F2, quote: 0xEDC4E5, strong: 0xF5E3B5,
        marker: 0xA5E0D5, failure: 0xE5737F, isDisplayP3: true)
    case ("nord", false):
      Self(
        0xECEFF4, 0x4C566A, dim: 0x7B8394, heading: 0xB4602F, emphasis: 0xA3497A,
        code: 0x4E7A3A, link: 0x355E86, path: 0x2F5F8F, quote: 0x7D5F8E, strong: 0x8A6A1E,
        marker: 0x3A7C80, failure: 0xBF616A)
    case ("dracula", true):
      Self(
        0x282A36, 0xD7D8DC, dim: 0x6272A4, heading: 0xFFB86C, emphasis: 0xFF79C6,
        code: 0x50FA7B, link: 0xBE95F9, path: 0x8BE9FD, quote: 0xD6BCFA, strong: 0xF1FA8C,
        marker: 0x8BE9FD, failure: 0xFF5555)
    case ("dracula", false):
      Self(
        0xF7F5FD, 0x2A2734, dim: 0x6C664B, heading: 0xA34D14, emphasis: 0xA3144D,
        code: 0x14710A, link: 0x7C3AED, path: 0x036A96, quote: 0x644AC9, strong: 0x846E15,
        marker: 0x036A96, failure: 0xCB3A2A)
    case ("github", true):
      Self(
        0x0D1117, 0xC9D1D9, dim: 0x8B949E, heading: 0xFFA657, emphasis: 0xD2A8FF,
        code: 0x7EE787, link: 0x58A6FF, path: 0x79C0FF, quote: 0xD2A8FF, strong: 0xE3B341,
        marker: 0x39C5CF, failure: 0xFF7B72)
    case ("github", false):
      Self(
        0xF6F8FA, 0x1F2328, dim: 0x59636E, heading: 0x953800, emphasis: 0x8250DF,
        code: 0x116329, link: 0x0969DA, path: 0x0550AE, quote: 0x6639BA, strong: 0x7D4E00,
        marker: 0x1B7C83, failure: 0xCF222E)
    case ("catppuccin", true):
      Self(
        0x1E1E2E, 0xBAC2DE, dim: 0x7F849C, heading: 0xFAB387, emphasis: 0xF5C2E7,
        code: 0xA6E3A1, link: 0x89B4FA, path: 0x74C7EC, quote: 0xB4BEFE, strong: 0xF9E2AF,
        marker: 0x94E2D5, failure: 0xF38BA8)
    case ("catppuccin", false):
      Self(
        0xEFF1F5, 0x4C4F69, dim: 0x7C7F93, heading: 0xFE640B, emphasis: 0xEA76CB,
        code: 0x40A02B, link: 0x1E66F5, path: 0x209FB5, quote: 0x8839EF, strong: 0xDF8E1D,
        marker: 0x179299, failure: 0xD20F39)
    case ("gruvbox", true):
      Self(
        0x282828, 0xD5C4A1, dim: 0x928374, heading: 0xFE8019, emphasis: 0xD3869B,
        code: 0xB8BB26, link: 0x83A598, path: 0x83A598, quote: 0xD3869B, strong: 0xFABD2F,
        marker: 0x8EC07C, failure: 0xFB4934)
    case ("gruvbox", false):
      Self(
        0xFBF1C7, 0x3C3836, dim: 0x7C6F64, heading: 0xAF3A03, emphasis: 0x8F3F71,
        code: 0x79740E, link: 0x076678, path: 0x076678, quote: 0x8F3F71, strong: 0xB57614,
        marker: 0x427B58, failure: 0x9D0006)
    case ("solarized", true):
      Self(
        0x002B36, 0x839496, dim: 0x586E75, heading: 0xCB4B16, emphasis: 0xD33682,
        code: 0x859900, link: 0x268BD2, path: 0x268BD2, quote: 0x6C71C4, strong: 0xB58900,
        marker: 0x2AA198, failure: 0xDC322F)
    case ("solarized", false):
      Self(
        0xFDF6E3, 0x586E75, dim: 0x839496, heading: 0xCB4B16, emphasis: 0xD33682,
        code: 0x859900, link: 0x268BD2, path: 0x268BD2, quote: 0x6C71C4, strong: 0xB58900,
        marker: 0x2AA198, failure: 0xDC322F)
    case (_, true):
      // Omnigent: the brand pink for emphasis over the deep violet canvas.
      Self(
        0x0E0B19, 0xC4BFD3, dim: 0x6F6884, heading: 0xF5A97F, emphasis: 0xF07AB0,
        code: 0x9EE6A8, link: 0x72B7F5, path: 0x8AB4F8, quote: 0xC9A7F0, strong: 0xF3E3B5,
        marker: 0x8FE3D6, failure: 0xE65B77)
    case (_, false):
      Self(
        0xFFFFFF, 0x2B2838, dim: 0x6E6A7C, heading: 0xB4501A, emphasis: 0xC42C72,
        code: 0x1E7A3A, link: 0x1967B5, path: 0x1D5FA8, quote: 0x7A3FB0, strong: 0x7A5A00,
        marker: 0x0F7C74, failure: 0xC8324C)
    }
  }
}

/// The CLI's semantic colors, derived from a theme's ``TerminalScheme`` and adjusted so every
/// text role reaches WCAG AA (4.5:1) on the surface it sits on, or 7:1 for body text under
/// Increase Contrast. Markers and rules are graphics and need 3:1 only when they carry meaning.
nonisolated public struct CLIPalette: Hashable, Sendable {
  /// The transcript canvas.
  var canvas: SRGB
  /// The user input band.
  var band: SRGB
  /// The composer band.
  var composerBand: SRGB
  /// Assistant body text.
  var body: SRGB
  /// User input text in the band.
  var userText: SRGB
  /// The `›` prompt glyph.
  var prompt: SRGB
  /// The `•` block bullet.
  var bullet: SRGB
  /// `##` headings.
  var heading: SRGB
  /// Bold.
  var bold: SRGB
  /// Italic.
  var italic: SRGB
  /// Inline code.
  var code: SRGB
  /// Links.
  var link: SRGB
  /// Paths and tool subjects.
  var path: SRGB
  /// Block quotes.
  var quote: SRGB
  /// Table headers and minor headings.
  var strong: SRGB
  /// List markers.
  var marker: SRGB
  /// Table rules and hairlines.
  var rule: SRGB
  /// "Worked for", timestamps and the status line.
  var dim: SRGB
  /// The composer placeholder.
  var placeholder: SRGB
  /// Failures.
  var failure: SRGB
  /// Added lines and counts.
  var added: SRGB
  /// "Needs you": the theme's brand accent.
  var needsYou: SRGB
  /// The selection highlight.
  var selection: SRGB

  /// Minimum contrast for text: WCAG AA, or AAA under Increase Contrast.
  static func textMinimum(increased: Bool) -> Double { increased ? 7 : 4.5 }
  /// Minimum contrast for body text: a step above the dim text, so footers stay quieter.
  static func bodyMinimum(increased: Bool) -> Double { increased ? 8.5 : 5.5 }

  /// Derives the palette.
  /// - Parameters:
  ///   - theme: The active theme.
  ///   - dark: The dark variant.
  ///   - increasedContrast: Increase Contrast is on.
  init(theme: OmnigentTheme, dark: Bool, increasedContrast: Bool) {
    let scheme = TerminalScheme.scheme(for: theme, dark: dark)
    let text = Self.textMinimum(increased: increasedContrast)
    let graphic = increasedContrast ? 4.5 : 3
    let isDark = scheme.background.isDark
    let lift: SRGB = isDark ? .white : .black
    // A mid-tone Custom background is pushed away from the text until body text can reach its
    // minimum with room to spare; the built-in palettes already have that room.
    let canvas = Self.withHeadroom(
      scheme.background, toward: isDark ? .black : .white, text: lift,
      minimum: Self.bodyMinimum(increased: increasedContrast) + 1.5)
    let band = Self.band(
      canvas, lift: lift, amount: isDark ? (increasedContrast ? 0.22 : 0.15) : 0.07, text: text)
    let composerBand = Self.band(
      canvas, lift: lift, amount: isDark ? (increasedContrast ? 0.18 : 0.11) : 0.05, text: text)
    func onCanvas(_ color: SRGB, _ minimum: Double) -> SRGB {
      color.ensuringContrast(minimum, against: [canvas])
    }
    self.canvas = canvas
    self.band = band
    self.composerBand = composerBand
    body = onCanvas(scheme.foreground, Self.bodyMinimum(increased: increasedContrast))
    userText = scheme.foreground.ensuringContrast(text, against: [band, composerBand])
    prompt = scheme.dim.ensuringContrast(graphic, against: [band, composerBand])
    bullet = onCanvas(scheme.dim, graphic)
    heading = onCanvas(scheme.heading, text)
    bold = onCanvas(scheme.emphasis, text)
    italic = onCanvas(scheme.emphasis, text)
    code = onCanvas(scheme.code, text)
    link = onCanvas(scheme.link, text)
    path = onCanvas(scheme.path, text)
    quote = onCanvas(scheme.quote, text)
    strong = onCanvas(scheme.strong, text)
    marker = onCanvas(scheme.marker, graphic)
    rule = canvas.mixed(with: scheme.foreground, by: increasedContrast ? 0.45 : 0.16)
    dim = onCanvas(scheme.dim, text)
    placeholder = scheme.dim.ensuringContrast(text, against: [composerBand])
    failure = onCanvas(scheme.failure, text)
    added = onCanvas(SRGB(dark ? StatusColors.diffAdded.dark : StatusColors.diffAdded.light), text)
    needsYou = onCanvas(SRGB((dark ? theme.dark : theme.light).brandAccent), text)
    selection = scheme.link.mixed(with: canvas, by: 0.6)
  }

  /// `background` moved toward `away` until `text` reaches `minimum` contrast on it.
  static func withHeadroom(_ background: SRGB, toward away: SRGB, text: SRGB, minimum: Double)
    -> SRGB
  {
    var color = background
    var step = 0
    while SRGB.contrast(text, color) < minimum, step < 50 {
      color = color.mixed(with: away, by: 0.05)
      step += 1
    }
    return color
  }

  /// The canvas lifted by `amount`, but never so far that the strongest text color loses the
  /// text minimum (with a margin) on it.
  static func band(_ canvas: SRGB, lift: SRGB, amount: Double, text: Double) -> SRGB {
    var amount = amount
    var band = canvas.mixed(with: lift, by: amount)
    let strongest: SRGB = lift == .white ? .white : .black
    while SRGB.contrast(strongest, band) < text + 0.5, amount > 0.02 {
      amount -= 0.02
      band = canvas.mixed(with: lift, by: amount)
    }
    return band
  }

  /// A text role and the surfaces it must read on.
  struct TextRole {
    let name: String
    let color: SRGB
    let backgrounds: [SRGB]

    init(_ name: String, _ color: SRGB, _ backgrounds: [SRGB]) {
      self.name = name
      self.color = color
      self.backgrounds = backgrounds
    }
  }

  /// Every text role, for the contrast check.
  var textRoles: [TextRole] {
    [
      TextRole("body", body, [canvas]), TextRole("userText", userText, [band, composerBand]),
      TextRole("heading", heading, [canvas]), TextRole("bold", bold, [canvas]),
      TextRole("italic", italic, [canvas]), TextRole("code", code, [canvas]),
      TextRole("link", link, [canvas]), TextRole("path", path, [canvas]),
      TextRole("quote", quote, [canvas]), TextRole("strong", strong, [canvas]),
      TextRole("dim", dim, [canvas]), TextRole("placeholder", placeholder, [composerBand]),
      TextRole("failure", failure, [canvas]), TextRole("added", added, [canvas]),
      TextRole("needsYou", needsYou, [canvas]),
    ]
  }
}

extension EnvironmentValues {
  /// The CLI colors for the active theme. Set by ``SwiftUICore/View/cliPalette()``.
  @Entry var cliPalette = CLIPalette.fallback
}

extension View {
  /// Derives the CLI colors from the theme, scheme and contrast, once per screen. In CLI style,
  /// native cards, the dock and the canvas sit on the CLI canvas.
  func cliPalette() -> some View { modifier(CLIPaletteProvider()) }
}

private struct CLIPaletteProvider: ViewModifier {
  @Environment(\.omnigentTheme) private var theme
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.transcriptAppearance) private var appearance

  func body(content: Content) -> some View {
    let dark = colorScheme == .dark
    if appearance.isCLI {
      let palette = CLIPaletteCache.palette(
        theme: theme, dark: dark, increasedContrast: contrast == .increased)
      content
        .environment(\.cliPalette, palette)
        .environment(
          \.omnigentTheme, CLIPaletteCache.canvasTheme(theme, palette: palette, dark: dark))
    } else {
      content
    }
  }
}

/// Derived palettes and CLI-canvas themes, computed once per theme, scheme and contrast. Each
/// view update then gets the same values back, so nothing downstream sees a change.
@MainActor
enum CLIPaletteCache {
  private struct Key: Hashable {
    let theme: OmnigentTheme
    let dark: Bool
    let increasedContrast: Bool
  }

  private static var palettes: [Key: CLIPalette] = [:]
  private static var themes: [Key: OmnigentTheme] = [:]

  static func palette(theme: OmnigentTheme, dark: Bool, increasedContrast: Bool) -> CLIPalette {
    let key = Key(theme: theme, dark: dark, increasedContrast: increasedContrast)
    if let cached = palettes[key] { return cached }
    let palette = CLIPalette(theme: theme, dark: dark, increasedContrast: increasedContrast)
    palettes[key] = palette
    return palette
  }

  static func canvasTheme(_ theme: OmnigentTheme, palette: CLIPalette, dark: Bool)
    -> OmnigentTheme
  {
    let key = Key(theme: theme, dark: dark, increasedContrast: false)
    if let cached = themes[key],
      cached.palette(for: dark ? .dark : .light).canvas
        == palette.canvas.color
    {
      return cached
    }
    let canvasTheme = palette.canvasTheme(theme, dark: dark)
    themes[key] = canvasTheme
    return canvasTheme
  }
}

extension CLIPalette {
  /// `theme` with the CLI canvas in the active scheme, so native surfaces sit on the terminal
  /// background. The other scheme is untouched (code cards always derive from the dark one).
  func canvasTheme(_ theme: OmnigentTheme, dark: Bool) -> OmnigentTheme {
    var copy = theme
    let keyPath = dark ? \OmnigentTheme.dark : \OmnigentTheme.light
    copy[keyPath: keyPath].canvas = canvas.color
    copy[keyPath: keyPath].canvasGlow = false
    return copy
  }
}

/// The CLI canvas behind the transcript, dock and composer.
struct CLICanvas: View {
  @Environment(\.cliPalette) private var palette

  var body: some View {
    palette.canvas.color.ignoresSafeArea().accessibilityHidden(true)
  }
}
