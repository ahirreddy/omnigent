public import SwiftUI

/// Settings > Appearance, as on the web: Mode (System, Light, Dark), Terminal theme, Transcript
/// (style, output rendering, width, CLI font size), and Color theme (the presets plus Custom
/// with Accent, Background tint, Contrast and Translucent sidebars). Editing a color on a preset turns it into Custom based on that preset. Values are
/// stored under the web's keys by ``ThemePreferences``.
public struct ThemeSettingsView: View {
  @Bindable private var preferences: ThemePreferences
  @Environment(\.colorScheme) private var colorScheme

  /// Creates the section.
  /// - Parameter preferences: The device's appearance preferences.
  public init(preferences: ThemePreferences) {
    self.preferences = preferences
  }

  /// The section.
  public var body: some View {
    Section("Theme") {
      Picker("Mode", selection: $preferences.mode) {
        ForEach(AppearancePreference.allCases) { Text($0.title).tag($0) }
      }
      .pickerStyle(.segmented)
      .tint(Theme.secondary)
      .accessibilityIdentifier("settings.appearance")
      Picker("Terminal theme", selection: $preferences.terminal) {
        ForEach(TerminalThemePreference.allCases) { Text($0.title).tag($0) }
      }
      .accessibilityIdentifier("settings.terminal-theme")
    }
    TranscriptSettingsSection(preferences: preferences.transcript)
    Section {
      Picker("Theme palette", selection: $preferences.paletteID) {
        ForEach(preferences.themes) { theme in
          HStack(spacing: 8) {
            ThemeSwatch(theme: theme)
            Text(theme.name)
          }
          .tag(theme.id)
        }
      }
      .accessibilityIdentifier("settings.theme")
      ColorPicker("Accent", selection: colorBinding(accent: true), supportsOpacity: false)
      ColorPicker("Background tint", selection: colorBinding(accent: false), supportsOpacity: false)
      LabeledContent("Contrast") {
        Slider(value: customBinding(\.contrast), in: 0...100)
          .frame(maxWidth: 200)
      }
      Toggle("Translucent sidebars", isOn: customBinding(\.translucentSidebar))
    } header: {
      Text("Color theme")
    } footer: {
      VStack(alignment: .leading, spacing: 4) {
        Text(preferences.theme.blurb)
        Text(
          "Accent and Background tint edit the \(colorScheme == .dark ? "dark" : "light") variant.")
        ForEach(preferences.readErrors, id: \.description) { error in
          Label(error.description, systemImage: "exclamationmark.triangle")
            .foregroundStyle(Theme.warning)
        }
      }
    }
  }

  /// Edits the custom theme, first basing it on the current preset when one is selected.
  private func customBinding<Value>(_ keyPath: WritableKeyPath<CustomTheme, Value>) -> Binding<
    Value
  > {
    Binding(
      get: { preferences.custom[keyPath: keyPath] },
      set: { value in
        becomeCustom()
        preferences.custom[keyPath: keyPath] = value
      })
  }

  private func colorBinding(accent: Bool) -> Binding<Color> {
    let dark = colorScheme == .dark
    let keyPath: WritableKeyPath<CustomTheme, String> =
      accent ? (dark ? \.darkAccent : \.accent) : (dark ? \.darkTint : \.tint)
    return Binding(
      get: {
        if preferences.paletteID == "custom" {
          return RGB(hex: preferences.custom[keyPath: keyPath]).color
        }
        let palette = preferences.theme.palette(for: colorScheme)
        return accent ? palette.accent : (palette.canvas ?? Color(white: dark ? 0 : 1))
      },
      set: { color in
        becomeCustom()
        preferences.custom[keyPath: keyPath] = Self.hex(color)
      })
  }

  private func becomeCustom() {
    guard preferences.paletteID != "custom" else { return }
    let base = OmnigentTheme.named(preferences.paletteID)
    preferences.custom = CustomTheme(
      basePalette: base.id, accent: Self.hex(base.light.accent),
      darkAccent: Self.hex(base.dark.accent), tint: Self.hex(base.light.canvas ?? .white),
      darkTint: Self.hex(base.dark.canvas ?? .black), contrast: preferences.custom.contrast,
      translucentSidebar: preferences.custom.translucentSidebar)
    preferences.paletteID = "custom"
  }

  /// `#rrggbb` for a color, gamma-encoding SwiftUI's linear components.
  static func hex(_ color: Color) -> String {
    let resolved = color.resolve(in: EnvironmentValues())
    func encode(_ linear: Float) -> Int {
      let value = Double(max(0, min(1, linear)))
      let gamma = value <= 0.003_130_8 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055
      return Int((gamma * 255).rounded())
    }
    let channels = [resolved.linearRed, resolved.linearGreen, resolved.linearBlue].map { linear in
      let digits = String(encode(linear), radix: 16)
      return digits.count == 1 ? "0" + digits : digits
    }
    return "#" + channels.joined()
  }
}

/// A small preview of a theme's accent, brand accent and canvas in the current scheme.
struct ThemeSwatch: View {
  let theme: OmnigentTheme
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    let palette = theme.palette(for: colorScheme)
    let colors = [palette.accent, palette.brandAccent, palette.canvas ?? Color(white: 0.5)]
    HStack(spacing: 2) {
      ForEach(colors.indices, id: \.self) { index in
        Circle().fill(colors[index]).frame(width: 9, height: 9)
          .overlay { Circle().strokeBorder(.separator, lineWidth: 0.5) }
      }
    }
    .accessibilityHidden(true)
  }
}
