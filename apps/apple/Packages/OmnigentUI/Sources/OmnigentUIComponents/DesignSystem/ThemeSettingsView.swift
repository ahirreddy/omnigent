public import SwiftUI

/// The appearance settings: light, dark or system, and the color theme. Bind both to stored
/// preferences and apply them with ``SwiftUICore/View/omnigentTheme(_:appearance:)`` at the root.
public struct ThemeSettingsView: View {
  @Binding private var themeID: String
  @Binding private var appearance: AppearancePreference
  private let themes: [OmnigentTheme]

  /// Creates the settings section.
  /// - Parameters:
  ///   - themeID: The selected theme's id.
  ///   - appearance: Light, dark or system.
  ///   - themes: The themes to offer.
  public init(
    themeID: Binding<String>, appearance: Binding<AppearancePreference>,
    themes: [OmnigentTheme] = OmnigentTheme.builtIn
  ) {
    _themeID = themeID
    _appearance = appearance
    self.themes = themes
  }

  /// The section.
  public var body: some View {
    Section("Appearance") {
      Picker("Appearance", selection: $appearance) {
        ForEach(AppearancePreference.allCases) { preference in
          Text(preference.title).tag(preference)
        }
      }
      .pickerStyle(.segmented)
      .accessibilityIdentifier("settings.appearance")
      Picker("Theme", selection: $themeID) {
        ForEach(themes) { theme in
          HStack(spacing: 8) {
            ThemeSwatch(theme: theme)
            Text(theme.name)
          }
          .tag(theme.id)
        }
      }
      .accessibilityIdentifier("settings.theme")
    }
  }
}

/// A small preview of a theme's accent and status colors.
struct ThemeSwatch: View {
  let theme: OmnigentTheme
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    let palette = theme.palette(for: colorScheme)
    let colors = [palette.accent, palette.running, palette.attention, palette.failure]
    HStack(spacing: 2) {
      ForEach(colors.indices, id: \.self) { index in
        Circle().fill(colors[index]).frame(width: 8, height: 8)
      }
    }
    .accessibilityHidden(true)
  }
}
