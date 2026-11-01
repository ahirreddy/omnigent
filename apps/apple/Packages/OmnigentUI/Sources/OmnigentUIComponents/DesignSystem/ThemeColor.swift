public import SwiftUI

/// A theme color resolved at render time from the environment's theme and color scheme, so a
/// theme switch restyles everything live.
nonisolated public struct ThemeColor: ShapeStyle, Hashable, Sendable {
  enum Role: Hashable, Sendable {
    case accent
    case brandAccent
    case link
    case selection
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
    case primary
    case secondary
    case fixed(Color)
  }

  let role: Role
  var alpha: Double = 1

  /// `--primary`.
  public static let accent = Self(role: .accent)
  /// `--brand-accent`: unread, "Needs response", the Inbox count.
  public static let brandAccent = Self(role: .brandAccent)
  /// `--link`.
  public static let link = Self(role: .link)
  /// `--selection-background`.
  public static let selection = Self(role: .selection)
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
    let base = brand(environment) ?? status(environment.colorScheme == .dark) ?? fallback
    return alpha == 1 ? base : base.opacity(alpha)
  }

  private func brand(_ environment: EnvironmentValues) -> Color? {
    let palette = environment.omnigentTheme.palette(for: environment.colorScheme)
    switch role {
    case .accent: return palette.accent
    case .brandAccent: return palette.brandAccent
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
