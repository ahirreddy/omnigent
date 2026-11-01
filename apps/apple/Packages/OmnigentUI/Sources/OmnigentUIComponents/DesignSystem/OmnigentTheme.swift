public import SwiftUI

/// The brand layer of one theme in one color scheme (web `--primary`, `--brand-accent`,
/// `--link`, `--selection-background`, `--background`, `--sidebar`). Text, separators, menus,
/// controls and materials stay system; status colors are constant across themes
/// (``StatusColors``).
nonisolated public struct ThemePalette: Hashable, Sendable {
  /// `--primary`: prominent buttons, selection, focus, the send button and Share.
  public var accent: Color
  /// `--brand-accent`: the unread dot, the "Needs response" badge, the Inbox count, skills.
  public var brandAccent: Color
  /// `--link`: links in markdown.
  public var link: Color
  /// `--selection-background`: text selection highlight.
  public var selection: Color
  /// `--background`: the detail canvas behind the transcript; `nil` keeps the system background.
  public var canvas: Color?
  /// Draw the web's center glow over the canvas (dark mode).
  public var canvasGlow: Bool
  /// `--sidebar` laid over the system sidebar material; `nil` leaves the material untinted.
  public var sidebarTint: Color?
  /// A wash at the bottom of the sidebar (the Omnigent dark sidebar's purple), if any.
  public var sidebarWash: Color?

  /// Creates a palette.
  /// - Parameters:
  ///   - accent: `--primary`.
  ///   - brandAccent: `--brand-accent`; defaults to the accent.
  ///   - link: `--link`.
  ///   - selection: `--selection-background`.
  ///   - canvas: `--background`, or `nil` for the system background.
  ///   - canvasGlow: Draw the center glow.
  ///   - sidebarTint: Sidebar tint, or `nil`.
  ///   - sidebarWash: Sidebar bottom wash, or `nil`.
  public init(
    accent: Color, brandAccent: Color? = nil, link: Color, selection: Color, canvas: Color?,
    canvasGlow: Bool = false, sidebarTint: Color? = nil, sidebarWash: Color? = nil
  ) {
    self.accent = accent
    self.brandAccent = brandAccent ?? accent
    self.link = link
    self.selection = selection
    self.canvas = canvas
    self.canvasGlow = canvasGlow
    self.sidebarTint = sidebarTint
    self.sidebarWash = sidebarWash
  }
}

/// A selectable color theme with light and dark variants, applied on top of native components.
/// Ids are the web's palette ids, so the stored preference is the same on web and native.
nonisolated public struct OmnigentTheme: Hashable, Sendable, Identifiable {
  /// The web palette id (`omni`, `dracula`, ..., `custom`).
  public var id: String
  /// The display name.
  public var name: String
  /// The web's one-line description.
  public var blurb: String
  /// The light variant.
  public var light: ThemePalette
  /// The dark variant.
  public var dark: ThemePalette

  /// Creates a theme.
  /// - Parameters:
  ///   - id: Web palette id.
  ///   - name: Display name.
  ///   - blurb: Description.
  ///   - light: Light palette.
  ///   - dark: Dark palette.
  public init(id: String, name: String, blurb: String = "", light: ThemePalette, dark: ThemePalette)
  {
    self.id = id
    self.name = name
    self.blurb = blurb
    self.light = light
    self.dark = dark
  }

  /// The palette for `scheme`.
  /// - Parameter scheme: The active color scheme.
  /// - Returns: The palette.
  public func palette(for scheme: ColorScheme) -> ThemePalette {
    scheme == .dark ? dark : light
  }

  /// The built-in themes, in the web's order. Custom is built from a ``CustomTheme``.
  public static let builtIn: [Self] = [
    .omni, .dracula, .github, .catppuccin, .gruvbox, .solarized, .nord,
  ]

  /// The built-in theme with `id`, or ``omni``.
  /// - Parameter id: A stored palette id.
  /// - Returns: The theme.
  public static func named(_ id: String) -> Self {
    builtIn.first { $0.id == id } ?? .omni
  }
}

nonisolated extension OmnigentTheme {
  /// "Omnigent": the signature pink brand look (the default).
  public static let omni = Self(
    id: "omni", name: "Omnigent", blurb: "The signature pink brand look.",
    light: ThemePalette(
      accent: Color(hex: 0xDF3C85), link: Color(hex: 0x1967B5),
      selection: Color(hex: 0xDF3C85, alpha: 0.10), canvas: nil),
    dark: ThemePalette(
      accent: Color(hex: 0xDF3C85), link: Color(hex: 0x72B7F5),
      selection: Color(hex: 0xDF3C85, alpha: 0.15), canvas: Color(hex: 0x0E0B19),
      canvasGlow: true, sidebarTint: Color(hex: 0x0E0B19),
      sidebarWash: Color(red: 92 / 255, green: 48 / 255, blue: 108 / 255, opacity: 0.2)))

  /// "Dracula": moody purple with a pink pop.
  public static let dracula = Self(
    id: "dracula", name: "Dracula", blurb: "Moody purple with a pink pop.",
    light: ThemePalette(
      accent: Color(hex: 0x7C3AED), brandAccent: Color(hex: 0xD6409F), link: Color(hex: 0x7C3AED),
      selection: Color(hex: 0x7C3AED, alpha: 0.15), canvas: Color(hex: 0xF7F5FD),
      sidebarTint: Color(hex: 0xF3F0FA)),
    dark: ThemePalette(
      accent: Color(hex: 0xBD93F9), brandAccent: Color(hex: 0xFF79C6), link: Color(hex: 0xBE95F9),
      selection: Color(hex: 0xBD93F9, alpha: 0.33), canvas: Color(hex: 0x282A36), canvasGlow: true,
      sidebarTint: Color(hex: 0x21222C, alpha: 0.8)))

  /// "GitHub": clean neutrals with a signal blue.
  public static let github = Self(
    id: "github", name: "GitHub", blurb: "Clean neutrals with a signal blue.",
    light: ThemePalette(
      accent: Color(hex: 0x0969DA), link: Color(hex: 0x0968D9),
      selection: Color(hex: 0x0969DA, alpha: 0.15), canvas: Color(hex: 0xF6F8FA),
      sidebarTint: Color(hex: 0xF6F8FA)),
    dark: ThemePalette(
      accent: Color(hex: 0x58A6FF), link: Color(hex: 0x58A6FF),
      selection: Color(hex: 0x58A6FF, alpha: 0.39), canvas: Color(hex: 0x0D1117), canvasGlow: true,
      sidebarTint: Color(hex: 0x0D1117, alpha: 0.75)))

  /// "Catppuccin": soft pastels, Latte and Mocha.
  public static let catppuccin = Self(
    id: "catppuccin", name: "Catppuccin", blurb: "Soft pastels \u{2014} Latte & Mocha.",
    light: ThemePalette(
      accent: Color(hex: 0x8839EF), brandAccent: Color(hex: 0xEA76CB), link: Color(hex: 0x8739EC),
      selection: Color(hex: 0x8839EF, alpha: 0.15), canvas: Color(hex: 0xEFF1F5),
      sidebarTint: Color(hex: 0xE6E9EF)),
    dark: ThemePalette(
      accent: Color(hex: 0xCBA6F7), link: Color(hex: 0xCBA6F7),
      selection: Color(hex: 0xCBA6F7, alpha: 0.26), canvas: Color(hex: 0x1E1E2E), canvasGlow: true,
      sidebarTint: Color(hex: 0x181825, alpha: 0.8)))

  /// "Gruvbox": warm retro earth tones.
  public static let gruvbox = Self(
    id: "gruvbox", name: "Gruvbox", blurb: "Warm retro earth tones.",
    light: ThemePalette(
      accent: Color(hex: 0xD65D0E), link: Color(hex: 0x9D360A),
      selection: Color(hex: 0xD65D0E, alpha: 0.18), canvas: Color(hex: 0xFBF1C7),
      sidebarTint: Color(hex: 0xF4E8BC)),
    dark: ThemePalette(
      accent: Color(hex: 0xFE8019), link: Color(hex: 0xFE8019),
      selection: Color(hex: 0xFE8019, alpha: 0.34), canvas: Color(hex: 0x282828), canvasGlow: true,
      sidebarTint: Color(hex: 0x1D2021, alpha: 0.8)))

  /// "Solarized": precision colors in Solarized Light and Dark.
  public static let solarized = Self(
    id: "solarized", name: "Solarized", blurb: "Precision colors in Solarized Light & Dark.",
    light: ThemePalette(
      accent: Color(hex: 0x268BD2), brandAccent: Color(hex: 0x6C71C4), link: Color(hex: 0x026287),
      selection: Color(hex: 0x268BD2, alpha: 0.15), canvas: Color(hex: 0xFDF6E3),
      sidebarTint: Color(hex: 0xEEE8D5)),
    dark: ThemePalette(
      accent: Color(hex: 0x268BD2), brandAccent: Color(hex: 0x6C71C4), link: Color(hex: 0x6AB8D0),
      selection: Color(hex: 0x268BD2, alpha: 0.42), canvas: Color(hex: 0x002B36), canvasGlow: true,
      sidebarTint: Color(hex: 0x073642)))

  /// "Nord": arctic frost blues over polar-night neutrals.
  public static let nord = Self(
    id: "nord", name: "Nord", blurb: "Arctic frost blues over polar-night neutrals.",
    light: ThemePalette(
      accent: Color(hex: 0x5E81AC), link: Color(hex: 0x355E86),
      selection: Color(hex: 0x5E81AC, alpha: 0.25), canvas: Color(hex: 0xECEFF4),
      sidebarTint: Color(hex: 0xE5E9F0)),
    dark: ThemePalette(
      accent: Color(hex: 0x88C0D0), link: Color(hex: 0x8FC4D3),
      selection: Color(hex: 0x88C0D0, alpha: 0.25), canvas: Color(hex: 0x2E3440), canvasGlow: true,
      sidebarTint: Color(hex: 0x2E3440, alpha: 0.8)))
}

/// Status colors from the web's `index.css`. They do not change with the color theme, only with
/// the color scheme.
nonisolated public enum StatusColors {
  /// `--success`.
  public static let success = (light: Color(hex: 0x2EA65C), dark: Color(hex: 0x2EA65C))
  /// `--warning`.
  public static let warning = (light: Color(hex: 0xD4972A), dark: Color(hex: 0xD4972A))
  /// `--info`.
  public static let info = (light: Color(hex: 0x3B8FF5), dark: Color(hex: 0x3B8FF5))
  /// `--destructive`.
  public static let destructive = (light: Color(hex: 0xC8324C), dark: Color(hex: 0xE65B77))
  /// `--session-active`.
  public static let sessionActive = (light: Color(hex: 0x2F7FD4), dark: Color(hex: 0x5CA4F5))
  /// Diff added lines.
  public static let diffAdded = (light: Color(hex: 0x16A34A), dark: Color(hex: 0x4ADE80))
  /// Diff removed lines.
  public static let diffRemoved = (light: Color(hex: 0xDC2626), dark: Color(hex: 0xF87171))
  /// Approval card icon.
  public static let approval = (light: Color(hex: 0xCA8A04), dark: Color(hex: 0xFACC15))
  /// Pull request open or ready.
  public static let prGreen = (light: Color(hex: 0x15803D), dark: Color(hex: 0x4ADE80))
  /// Pull request conflicts, failing or closed.
  public static let prRed = (light: Color(hex: 0xB91C1C), dark: Color(hex: 0xF87171))
  /// Pull request checks running.
  public static let prAmber = (light: Color(hex: 0xB45309), dark: Color(hex: 0xFBBF24))
  /// Pull request merged.
  public static let prPurple = (light: Color(hex: 0x7E22CE), dark: Color(hex: 0xC084FC))
}

nonisolated extension Color {
  /// A color from a 24-bit `0xRRGGBB` value.
  /// - Parameters:
  ///   - hex: The value.
  ///   - alpha: Opacity.
  public init(hex: UInt32, alpha: Double = 1) {
    self.init(
      .sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255, opacity: alpha)
  }
}

/// Light, dark, or following the system: the web's `web-theme` values.
nonisolated public enum AppearancePreference: String, Hashable, Sendable, CaseIterable,
  Identifiable
{
  /// Follow the system.
  case system
  /// Always light.
  case light
  /// Always dark.
  case dark

  /// The preference itself.
  public var id: Self { self }

  /// The display title.
  public var title: String {
    switch self {
    case .system: "System"
    case .light: "Light"
    case .dark: "Dark"
    }
  }

  /// The scheme to force, or `nil` to follow the system.
  public var colorScheme: ColorScheme? {
    switch self {
    case .system: nil
    case .light: .light
    case .dark: .dark
    }
  }
}

nonisolated extension EnvironmentValues {
  /// The active color theme. Set it with ``SwiftUICore/View/omnigentTheme(_:appearance:)``.
  @Entry public var omnigentTheme: OmnigentTheme = .omni
}

extension View {
  /// Applies a theme: its brand colors to the components, its accent as the tint of system
  /// controls, and the appearance preference.
  /// - Parameters:
  ///   - theme: The theme.
  ///   - appearance: Light, dark or system.
  /// - Returns: The themed view.
  public func omnigentTheme(_ theme: OmnigentTheme, appearance: AppearancePreference = .system)
    -> some View
  {
    tint(ThemeColor.accent)
      .environment(\.omnigentTheme, theme)
      .preferredColorScheme(appearance.colorScheme)
  }

  /// The theme's canvas behind content (with the dark-mode center glow), or the system
  /// background for themes without one.
  /// - Returns: The view on its canvas.
  public func themeCanvas() -> some View {
    background { ThemeCanvas() }
  }

  /// The theme's tint over a sidebar's system material (none when translucent).
  /// - Returns: The view with the tint behind it.
  public func themeSidebar() -> some View {
    background { ThemeSidebarTint() }
  }
}

struct ThemeCanvas: View {
  @Environment(\.omnigentTheme) private var theme
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    let palette = theme.palette(for: colorScheme)
    ZStack {
      if let canvas = palette.canvas {
        canvas
      } else {
        Rectangle().fill(.background)
      }
      if palette.canvasGlow, colorScheme == .dark {
        // `omnigent-center-glow.svg`: white radial gradient at 50% / 46%, 26% to 0%.
        GeometryReader { proxy in
          RadialGradient(
            colors: [.white.opacity(0.06), .white.opacity(0)],
            center: UnitPoint(x: 0.5, y: 0.46), startRadius: 0,
            endRadius: max(proxy.size.width, proxy.size.height) * 0.56)
        }
      }
    }
    .ignoresSafeArea()
  }
}

struct ThemeSidebarTint: View {
  @Environment(\.omnigentTheme) private var theme
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    let palette = theme.palette(for: colorScheme)
    ZStack {
      if let tint = palette.sidebarTint { tint }
      if let wash = palette.sidebarWash {
        LinearGradient(
          stops: [.init(color: .clear, location: 0.35), .init(color: wash, location: 1)],
          startPoint: .top, endPoint: .bottom)
      }
    }
    .ignoresSafeArea()
  }
}
