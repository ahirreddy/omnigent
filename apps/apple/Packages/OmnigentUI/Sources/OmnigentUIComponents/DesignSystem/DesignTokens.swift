public import SwiftUI

/// Colors and metrics shared with the Omnigent web UI.
public enum DesignTokens {
  /// Corner radius for cards and controls.
  public static let radius: CGFloat = 8

  /// Light-mode page background.
  public static let lightBackground = Color.white
  /// Light-mode primary text.
  public static let lightForeground = Color(red: 0.067, green: 0.090, blue: 0.110)
  /// Light-mode secondary text.
  public static let lightMutedForeground = Color(red: 0.435, green: 0.435, blue: 0.435)
  /// Light-mode hairline borders.
  public static let lightBorder = Color(red: 0.910, green: 0.925, blue: 0.941)

  /// Dark-mode page background.
  public static let darkBackground = Color(red: 0.118, green: 0.098, blue: 0.153)
  /// Dark-mode primary text.
  public static let darkForeground = Color(red: 0.910, green: 0.925, blue: 0.941)
  /// Dark-mode secondary text.
  public static let darkMutedForeground = Color(red: 0.572, green: 0.643, blue: 0.702)
  /// Dark-mode hairline borders.
  public static let darkBorder = Color(red: 0.215, green: 0.219, blue: 0.230)

  /// Page background for `scheme`.
  /// - Parameter scheme: The active color scheme.
  /// - Returns: The background color.
  public static func background(_ scheme: ColorScheme) -> Color {
    scheme == .dark ? darkBackground : lightBackground
  }

  /// Primary text color for `scheme`.
  /// - Parameter scheme: The active color scheme.
  /// - Returns: The text color.
  public static func foreground(_ scheme: ColorScheme) -> Color {
    scheme == .dark ? darkForeground : lightForeground
  }

  /// Secondary text color for `scheme`.
  /// - Parameter scheme: The active color scheme.
  /// - Returns: The text color.
  public static func mutedForeground(_ scheme: ColorScheme) -> Color {
    scheme == .dark ? darkMutedForeground : lightMutedForeground
  }

  /// Border color for `scheme`.
  /// - Parameter scheme: The active color scheme.
  /// - Returns: The border color.
  public static func border(_ scheme: ColorScheme) -> Color {
    scheme == .dark ? darkBorder : lightBorder
  }
}
