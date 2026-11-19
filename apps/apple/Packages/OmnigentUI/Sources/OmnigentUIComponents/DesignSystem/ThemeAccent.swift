public import SwiftUI

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

// The accent a window's controls and its primary action share: the color theme's by default,
// or the system's under Settings › Appearance › Use system accent.

nonisolated extension OmnigentTheme {
  /// The system's accent: the Mac's accent color, or iOS's tint.
  public static var systemAccent: Color {
    #if os(macOS)
      Color(nsColor: .controlAccentColor)
    #else
      Color(uiColor: .tintColor)
    #endif
  }

  /// This theme with the system's accent in place of its own, for Use system accent: the
  /// primary action, control tint, selection and selected rows follow it. "Needs you", links
  /// and the canvas keep the theme's colors.
  /// - Returns: The theme with the system accent.
  public func withSystemAccent() -> Self {
    var theme = self
    theme.light.accent = Self.systemAccent
    theme.light.selection = Self.systemAccent.opacity(0.12)
    theme.dark.accent = Self.systemAccent
    theme.dark.selection = Self.systemAccent.opacity(0.18)
    return theme
  }
}

extension View {
  /// Applies a theme: its brand colors to the components and the appearance preference. A
  /// window's root also tints its controls with ``omnigentAppearance(_:)``.
  /// - Parameters:
  ///   - theme: The theme.
  ///   - appearance: Light, dark or system.
  ///   - systemAccent: Use the system's accent in place of the theme's.
  /// - Returns: The themed view.
  public func omnigentTheme(
    _ theme: OmnigentTheme, appearance: AppearancePreference = .system,
    systemAccent: Bool = false
  ) -> some View {
    environment(\.omnigentTheme, systemAccent ? theme.withSystemAccent() : theme)
      .preferredColorScheme(appearance.colorScheme)
  }

  /// A window's appearance from the device's preferences: the theme and mode, and the accent
  /// (the theme's, or the system's under Use system accent) as the tint of every control, so
  /// radios, checkboxes, toggles, links and progress match the primary action. A theme or
  /// setting change restyles the window at once.
  /// - Parameter preferences: The device's appearance preferences.
  /// - Returns: The themed view.
  public func omnigentAppearance(_ preferences: ThemePreferences) -> some View {
    omnigentAppearance(
      preferences.theme, appearance: preferences.mode, systemAccent: preferences.usesSystemAccent)
  }

  /// A window's appearance: ``omnigentTheme(_:appearance:systemAccent:)`` with the resolved
  /// accent as every control's tint.
  /// - Parameters:
  ///   - theme: The theme.
  ///   - appearance: Light, dark or system.
  ///   - systemAccent: Use the system's accent in place of the theme's.
  /// - Returns: The themed view.
  public func omnigentAppearance(
    _ theme: OmnigentTheme, appearance: AppearancePreference = .system,
    systemAccent: Bool = false
  ) -> some View {
    tint(ThemeColor.controlTint)
      .omnigentTheme(theme, appearance: appearance, systemAccent: systemAccent)
  }
}

nonisolated extension EnvironmentValues {
  /// The accent controls, icons and selection draw in, resolved: the theme's, or the system's
  /// under Use system accent. Views use `.tint` or ``ThemeColor/controlTint``; AppKit and UIKit
  /// drawing converts this (`NSColor(controlAccent)`).
  public var controlAccent: Color { ThemeColor.controlTint.resolve(in: self) }
}
