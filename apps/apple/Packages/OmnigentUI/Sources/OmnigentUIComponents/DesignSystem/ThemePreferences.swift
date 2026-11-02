public import Foundation
public import Observation
import SwiftUI

/// The web's Custom theme (`lib/customTheme.ts`): accent and background tint per mode, contrast
/// and translucent sidebars, based on a preset. Encoded exactly as the web stores it under
/// `omnigent:custom-theme`.
nonisolated public struct CustomTheme: Codable, Hashable, Sendable {
  /// The preset it started from (a web palette id).
  public var basePalette: String
  /// Light accent, `#rrggbb`.
  public var accent: String
  /// Dark accent, `#rrggbb`.
  public var darkAccent: String
  /// Light background tint, `#rrggbb`.
  public var tint: String
  /// Dark background, `#rrggbb`.
  public var darkTint: String
  /// Contrast, 0 to 100.
  public var contrast: Double
  /// Leave the sidebar material untinted.
  public var translucentSidebar: Bool

  /// The web's default custom theme.
  public static let `default` = Self(
    basePalette: "omni", accent: "#df3c85", darkAccent: "#df3c85", tint: "#ffffff",
    darkTint: "#0e0b19", contrast: 50, translucentSidebar: false)

  /// Creates a custom theme.
  /// - Parameters:
  ///   - basePalette: Base preset id.
  ///   - accent: Light accent.
  ///   - darkAccent: Dark accent.
  ///   - tint: Light background tint.
  ///   - darkTint: Dark background.
  ///   - contrast: 0 to 100.
  ///   - translucentSidebar: Untinted sidebar.
  public init(
    basePalette: String, accent: String, darkAccent: String, tint: String, darkTint: String,
    contrast: Double, translucentSidebar: Bool
  ) {
    self.basePalette = basePalette
    self.accent = accent
    self.darkAccent = darkAccent
    self.tint = tint
    self.darkTint = darkTint
    self.contrast = contrast
    self.translucentSidebar = translucentSidebar
  }

  /// The theme these settings produce. The canvas and sidebar follow `generateCustomTheme` in
  /// the web (light background `mix(tint, #fffdff, 0.79 - 0.15c)`, dark background `darkTint`,
  /// sidebar a mix of background and card); links come from the base preset.
  /// - Returns: The theme, id `custom`.
  public func theme() -> OmnigentTheme {
    let base = OmnigentTheme.named(basePalette)
    let contrast = max(0, min(100, contrast)) / 100
    let lightBackground = RGB.mix(RGB(hex: tint), RGB(hex: "#fffdff"), 0.79 - contrast * 0.15)
    let darkBackground = RGB(hex: darkTint)
    let lightCard = RGB.mix(lightBackground, RGB(hex: "#ffffff"), 0.72 + contrast * 0.16)
    let darkCard = RGB.mix(darkBackground, RGB(hex: "#ffffff"), 0.05 + contrast * 0.08)
    let lightAccent = RGB(hex: accent).color
    let darkAccentColor = RGB(hex: darkAccent).color
    return OmnigentTheme(
      id: "custom", name: "Custom", blurb: "Your accent, background and contrast.",
      light: ThemePalette(
        accent: lightAccent, link: base.light.link, selection: lightAccent.opacity(0.12),
        canvas: lightBackground.color,
        sidebarTint: translucentSidebar ? nil : RGB.mix(lightBackground, lightCard, 0.42).color),
      dark: ThemePalette(
        accent: darkAccentColor, link: base.dark.link, selection: darkAccentColor.opacity(0.18),
        canvas: darkBackground.color, canvasGlow: true,
        sidebarTint: translucentSidebar ? nil : RGB.mix(darkBackground, darkCard, 0.34).color))
  }
}

/// An sRGB color as the web's hex helpers see it.
nonisolated struct RGB: Hashable {
  var red: Double
  var green: Double
  var blue: Double

  init(red: Double, green: Double, blue: Double) {
    self.red = red
    self.green = green
    self.blue = blue
  }

  /// Parses `#rrggbb`; anything else is black, as the web's normalizer rejects it upstream.
  init(hex: String) {
    let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    let value = digits.count == 6 ? UInt32(digits, radix: 16) ?? 0 : 0
    red = Double((value >> 16) & 0xFF)
    green = Double((value >> 8) & 0xFF)
    blue = Double(value & 0xFF)
  }

  static func mix(_ first: Self, _ second: Self, _ secondWeight: Double) -> Self {
    let weight = max(0, min(1, secondWeight))
    return Self(
      red: (first.red * (1 - weight) + second.red * weight).rounded(),
      green: (first.green * (1 - weight) + second.green * weight).rounded(),
      blue: (first.blue * (1 - weight) + second.blue * weight).rounded())
  }

  var color: Color { Color(.sRGB, red: red / 255, green: green / 255, blue: blue / 255) }
}

/// The terminal color scheme: the web's `omnigent:terminal-theme`.
nonisolated public enum TerminalThemePreference: String, Hashable, Sendable, CaseIterable,
  Identifiable
{
  /// "Match app".
  case auto
  /// Always light.
  case light
  /// Always dark.
  case dark

  /// The preference itself.
  public var id: Self { self }

  /// The display title.
  public var title: String {
    switch self {
    case .auto: "Match app"
    case .light: "Light"
    case .dark: "Dark"
    }
  }
}

/// Device-local appearance preferences, stored in `UserDefaults` under the web's
/// `localStorage` keys and value encodings, so a web Settings export imports unchanged.
@Observable
public final class ThemePreferences {
  /// `web-theme`.
  public static let modeKey = "web-theme"
  /// `omnigent:ui-theme-palette`, a JSON string; removed for `omni`.
  public static let paletteKey = "omnigent:ui-theme-palette"
  /// `omnigent:custom-theme`, a JSON object.
  public static let customKey = "omnigent:custom-theme"
  /// `omnigent:terminal-theme`.
  public static let terminalKey = "omnigent:terminal-theme"

  /// Why a stored value could not be read. Surfaced, never swallowed.
  public enum ReadError: Error, Equatable, CustomStringConvertible {
    /// The value under `key` is not what the web writes.
    case malformed(key: String)

    /// A readable message.
    public var description: String {
      switch self {
      case .malformed(let key):
        "The stored appearance setting \(key) is not valid; using the default."
      }
    }
  }

  /// Light, dark or system.
  public var mode: AppearancePreference {
    didSet { defaults.set(mode.rawValue, forKey: Self.modeKey) }
  }
  /// The palette id: a built-in id or `custom`.
  public var paletteID: String {
    didSet { writePalette() }
  }
  /// The custom theme settings.
  public var custom: CustomTheme {
    didSet { writeCustom() }
  }
  /// The terminal color scheme.
  public var terminal: TerminalThemePreference {
    didSet { defaults.set(terminal.rawValue, forKey: Self.terminalKey) }
  }
  /// Problems found reading stored values, for Settings to show.
  public private(set) var readErrors: [ReadError] = []
  /// The transcript style, width, output rendering and CLI font size, in the same store.
  public let transcript: TranscriptPreferences

  private let defaults: UserDefaults

  /// Loads preferences.
  /// - Parameter defaults: The store; `standard` by default.
  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    transcript = TranscriptPreferences(defaults: defaults)
    var errors: [ReadError] = []
    let storedMode = defaults.string(forKey: Self.modeKey)
    mode = storedMode.flatMap(AppearancePreference.init(rawValue:)) ?? .system
    if storedMode != nil, AppearancePreference(rawValue: storedMode ?? "") == nil {
      errors.append(.malformed(key: Self.modeKey))
    }
    switch Self.decodePalette(defaults.string(forKey: Self.paletteKey)) {
    case .success(let id): paletteID = id
    case .failure(let error):
      paletteID = OmnigentTheme.omni.id
      errors.append(error)
    }
    switch Self.decodeCustom(defaults.string(forKey: Self.customKey)) {
    case .success(let theme): custom = theme
    case .failure(let error):
      custom = .default
      errors.append(error)
    }
    let storedTerminal = defaults.string(forKey: Self.terminalKey)
    terminal = storedTerminal.flatMap(TerminalThemePreference.init(rawValue:)) ?? .auto
    if storedTerminal != nil, TerminalThemePreference(rawValue: storedTerminal ?? "") == nil {
      errors.append(.malformed(key: Self.terminalKey))
    }
    readErrors = errors
  }

  /// The active theme.
  public var theme: OmnigentTheme {
    paletteID == "custom" ? custom.theme() : OmnigentTheme.named(paletteID)
  }

  /// Every theme the picker offers: the presets and Custom.
  public var themes: [OmnigentTheme] { OmnigentTheme.builtIn + [custom.theme()] }

  static func decodePalette(_ stored: String?) -> Result<String, ReadError> {
    guard let stored else { return .success(OmnigentTheme.omni.id) }
    let malformed = ReadError.malformed(key: paletteKey)
    guard let data = stored.data(using: .utf8) else { return .failure(malformed) }
    do {
      let id = try JSONDecoder().decode(String.self, from: data)
      let known = OmnigentTheme.builtIn.contains { $0.id == id } || id == "custom"
      return known ? .success(id) : .failure(malformed)
    } catch {
      return .failure(malformed)
    }
  }

  static func decodeCustom(_ stored: String?) -> Result<CustomTheme, ReadError> {
    guard let stored else { return .success(.default) }
    guard let data = stored.data(using: .utf8) else {
      return .failure(.malformed(key: customKey))
    }
    do {
      return .success(try JSONDecoder().decode(CustomTheme.self, from: data))
    } catch {
      return .failure(.malformed(key: customKey))
    }
  }

  private func writePalette() {
    guard paletteID != OmnigentTheme.omni.id else {
      defaults.removeObject(forKey: Self.paletteKey)
      return
    }
    // A JSON string literal, as the web's `JSON.stringify(id)`.
    let escaped = paletteID.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    defaults.set("\"\(escaped)\"", forKey: Self.paletteKey)
  }

  private func writeCustom() {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    do {
      let data = try encoder.encode(custom)
      guard let json = String(bytes: data, encoding: .utf8) else {
        readErrors.append(.malformed(key: Self.customKey))
        return
      }
      defaults.set(json, forKey: Self.customKey)
    } catch {
      readErrors.append(.malformed(key: Self.customKey))
    }
  }
}
