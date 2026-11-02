public import SwiftUI

/// A theme color resolved at render time from the environment's theme and color scheme, so a
/// theme switch restyles everything live.
nonisolated public struct ThemeColor: ShapeStyle, Hashable, Sendable {
  enum Role: Hashable, Sendable {
    case accent
    case brandAccent
    case attention
    case attentionFill
    case mutedText
    case link
    case selection
    case rowSelection
    case focus
    case running
    case success
    case warning
    case info
    case failure
    case diffAdded
    case diffRemoved
    case approval
    case prGreen
    case prRed
    case prAmber
    case prPurple
    case userBubble
    case surface
    case border
    case hover
    case codeSurface
    case onAccent
    case primary
    case secondary
    case fixed(Color)
  }

  let role: Role
  var alpha: Double = 1

  /// `--primary`: the single primary action on a screen (Send, Approve, Submit), and nothing
  /// else. Toolbar items, chips, links, selection and decoration use the other roles. Darkened
  /// where needed so its label (``onAccent``) reads at WCAG AA, or AAA under Increase Contrast.
  public static let accent = Self(role: .accent)
  /// `--brand-accent` exactly as the palette defines it, for swatches. Draw "needs you" with
  /// ``attention``.
  public static let brandAccent = Self(role: .brandAccent)
  /// "Needs you" text and glyphs: the brand accent, with its lightness moved until it reads at
  /// WCAG AA (AAA under Increase Contrast) on the canvas, the sidebar, a selected row and its
  /// own 15% capsule.
  public static let attention = Self(role: .attention)
  /// The "needs you" capsule's tint behind ``attention`` text, laid over ``surface``.
  public static let attentionFill = Self(role: .attentionFill)
  /// Secondary text (section headers, metadata) that reads at WCAG AA on the canvas, the
  /// sidebar and a selected row, where the system's secondary label can fall below it.
  public static let mutedText = Self(role: .mutedText)
  /// `--link`.
  public static let link = Self(role: .link)
  /// `--selection-background`: the text selection highlight.
  public static let selection = Self(role: .selection)
  /// A selected row or item: the theme's hue, softened (the web's `--sidebar-active`).
  public static let rowSelection = Self(role: .rowSelection)
  /// A focused or drop-targeted field's border: neutral, so focus never reads as an action.
  public static let focus = Self(role: .focus)
  /// Running: muted, as the web's running spinner.
  public static let running = Self(role: .running)
  /// `--success`.
  public static let success = Self(role: .success)
  /// `--warning`.
  public static let warning = Self(role: .warning)
  /// `--info`.
  public static let info = Self(role: .info)
  /// `--destructive`.
  public static let failure = Self(role: .failure)
  /// Diff added lines.
  public static let diffAdded = Self(role: .diffAdded)
  /// Diff removed lines.
  public static let diffRemoved = Self(role: .diffRemoved)
  /// The approval card icon.
  public static let approval = Self(role: .approval)
  /// Pull request open or ready.
  public static let prGreen = Self(role: .prGreen)
  /// Pull request conflicts, failing or closed.
  public static let prRed = Self(role: .prRed)
  /// Pull request checks running.
  public static let prAmber = Self(role: .prAmber)
  /// Pull request merged.
  public static let prPurple = Self(role: .prPurple)
  /// The user bubble fill: neutral, as the web's `bg-muted`.
  public static let userBubble = Self(role: .userBubble)
  /// The system primary color.
  public static let primary = Self(role: .primary)
  /// The system secondary color.
  public static let secondary = Self(role: .secondary)

  static let surface = Self(role: .surface)
  static let border = Self(role: .border)
  static let hover = Self(role: .hover)
  static let codeSurface = Self(role: .codeSurface)
  static let onAccent = Self(role: .onAccent)

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
    let base =
      surface(environment) ?? brand(environment)
      ?? status(environment.colorScheme == .dark) ?? fallback
    return alpha == 1 ? base : base.opacity(alpha)
  }

  private func surface(_ environment: EnvironmentValues) -> Color? {
    let dark = environment.colorScheme == .dark
    let increased = environment.colorSchemeContrast == .increased
    let palette = environment.omnigentTheme.palette(for: environment.colorScheme)
    switch role {
    case .surface:
      let canvas = palette.canvas ?? (dark ? Color(white: 0.08) : .white)
      return canvas.mix(with: dark ? .white : .black, by: dark ? 0.06 : 0.025)
    case .border: return Color.primary.opacity(increased ? 0.5 : 0.14)
    case .hover: return Color.primary.opacity(increased ? 0.12 : 0.05)
    case .focus: return Color.primary.opacity(increased ? 0.6 : 0.3)
    case .rowSelection:
      return palette.accent.opacity(ThemeContrast.roles(in: environment).rowSelectionOpacity)
    case .codeSurface:
      return (environment.omnigentTheme.dark.canvas ?? Color(white: 0.08))
        .mix(with: .black, by: 0.18)
    case .onAccent: return ThemeContrast.roles(in: environment).onPrimary.color
    case .mutedText: return ThemeContrast.roles(in: environment).mutedText.color
    default: return nil
    }
  }

  private func brand(_ environment: EnvironmentValues) -> Color? {
    let palette = environment.omnigentTheme.palette(for: environment.colorScheme)
    switch role {
    case .accent: return ThemeContrast.roles(in: environment).primaryFill.color
    case .brandAccent: return palette.brandAccent
    case .attention: return ThemeContrast.roles(in: environment).attention.color
    case .attentionFill:
      let roles = ThemeContrast.roles(in: environment)
      return roles.attention.color.opacity(roles.capsuleOpacity)
    case .link: return palette.link
    case .selection: return palette.selection
    case .userBubble: return Color.primary.opacity(environment.colorScheme == .dark ? 0.1 : 0.06)
    default: return nil
    }
  }

  private static let statusPairs: [Role: (light: Color, dark: Color)] = [
    .success: StatusColors.success, .warning: StatusColors.warning, .info: StatusColors.info,
    .failure: StatusColors.destructive, .diffAdded: StatusColors.diffAdded,
    .diffRemoved: StatusColors.diffRemoved, .approval: StatusColors.approval,
    .prGreen: StatusColors.prGreen, .prRed: StatusColors.prRed, .prAmber: StatusColors.prAmber,
    .prPurple: StatusColors.prPurple,
  ]

  private func status(_ dark: Bool) -> Color? {
    Self.statusPairs[role].map { dark ? $0.dark : $0.light }
  }

  private var fallback: Color {
    switch role {
    case .primary: Color.primary
    case .fixed(let color): color
    default: Color.secondary
    }
  }
}
