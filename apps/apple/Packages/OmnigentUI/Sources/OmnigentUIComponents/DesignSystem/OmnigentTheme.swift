public import SwiftUI

/// The brand colors of one theme in one color scheme. Everything else (backgrounds, text,
/// separators, materials) comes from the system.
nonisolated public struct ThemePalette: Hashable, Sendable {
  /// The accent: prominent buttons, selection, links and the send button.
  public var accent: Color
  /// Running and live states.
  public var running: Color
  /// Needs-attention states: pending decisions, warnings.
  public var attention: Color
  /// Failures and destructive states.
  public var failure: Color
  /// The unread dot.
  public var unread: Color
  /// The user's message bubble fill.
  public var userBubble: Color
  /// An optional tint the theme lays faintly over card surfaces.
  public var surfaceTint: Color?

  /// Creates a palette.
  /// - Parameters:
  ///   - accent: Accent.
  ///   - running: Running state.
  ///   - attention: Attention state.
  ///   - failure: Failure state.
  ///   - unread: Unread dot.
  ///   - userBubble: User bubble fill.
  ///   - surfaceTint: Card surface tint.
  public init(
    accent: Color, running: Color = .green, attention: Color = .orange, failure: Color = .red,
    unread: Color? = nil, userBubble: Color? = nil, surfaceTint: Color? = nil
  ) {
    self.accent = accent
    self.running = running
    self.attention = attention
    self.failure = failure
    self.unread = unread ?? accent
    self.userBubble = userBubble ?? accent.opacity(0.12)
    self.surfaceTint = surfaceTint
  }
}

/// A selectable color theme with light and dark variants, applied on top of native components.
nonisolated public struct OmnigentTheme: Hashable, Sendable, Identifiable {
  /// A stable id, stored in preferences.
  public var id: String
  /// The display name.
  public var name: String
  /// The light variant.
  public var light: ThemePalette
  /// The dark variant.
  public var dark: ThemePalette

  /// Creates a theme.
  /// - Parameters:
  ///   - id: Stable id.
  ///   - name: Display name.
  ///   - light: Light palette.
  ///   - dark: Dark palette.
  public init(id: String, name: String, light: ThemePalette, dark: ThemePalette) {
    self.id = id
    self.name = name
    self.light = light
    self.dark = dark
  }

  /// The palette for `scheme`.
  /// - Parameter scheme: The active color scheme.
  /// - Returns: The palette.
  public func palette(for scheme: ColorScheme) -> ThemePalette {
    scheme == .dark ? dark : light
  }

  /// The default theme: the system blue accent and system status colors.
  public static let standard = Self(
    id: "standard", name: "Standard",
    light: ThemePalette(accent: Color(red: 0.0, green: 0.48, blue: 1.0)),
    dark: ThemePalette(accent: Color(red: 0.04, green: 0.52, blue: 1.0)))

  /// The themes the app ships. The web UI's named themes are added here.
  public static let builtIn: [Self] = [.standard]

  /// The built-in theme with `id`, or ``standard``.
  /// - Parameter id: A stored theme id.
  /// - Returns: The theme.
  public static func named(_ id: String) -> Self {
    builtIn.first { $0.id == id } ?? .standard
  }
}

/// Light, dark, or following the system.
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
  @Entry public var omnigentTheme: OmnigentTheme = .standard
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
}

/// A theme color resolved at render time from the environment's theme and color scheme, so a
/// theme switch restyles everything live.
nonisolated public struct ThemeColor: ShapeStyle, Hashable, Sendable {
  enum Role: Hashable, Sendable {
    case accent
    case running
    case attention
    case failure
    case unread
    case userBubble
    case primary
    case secondary
    case fixed(Color)
  }

  let role: Role
  var alpha: Double = 1

  /// The accent.
  public static let accent = Self(role: .accent)
  /// Running and live.
  public static let running = Self(role: .running)
  /// Needs attention.
  public static let attention = Self(role: .attention)
  /// Failure.
  public static let failure = Self(role: .failure)
  /// Unread.
  public static let unread = Self(role: .unread)
  /// The user bubble fill.
  public static let userBubble = Self(role: .userBubble)
  /// The system primary color.
  public static let primary = Self(role: .primary)
  /// The system secondary color.
  public static let secondary = Self(role: .secondary)

  /// A fixed system color that does not change with the theme.
  /// - Parameter color: The color.
  /// - Returns: The style.
  public static func system(_ color: Color) -> Self { Self(role: .fixed(color)) }

  /// The same color at `opacity` times its alpha.
  /// - Parameter opacity: 0 to 1.
  /// - Returns: The style.
  public func opacity(_ opacity: Double) -> Self {
    var copy = self
    copy.alpha *= opacity
    return copy
  }

  /// Resolves against the environment's theme and scheme.
  /// - Parameter environment: The environment.
  /// - Returns: The color.
  public func resolve(in environment: EnvironmentValues) -> Color {
    let palette = environment.omnigentTheme.palette(for: environment.colorScheme)
    let base: Color =
      switch role {
      case .accent: palette.accent
      case .running: palette.running
      case .attention: palette.attention
      case .failure: palette.failure
      case .unread: palette.unread
      case .userBubble: palette.userBubble
      case .primary: Color.primary
      case .secondary: Color.secondary
      case .fixed(let color): color
      }
    return alpha == 1 ? base : base.opacity(alpha)
  }
}
