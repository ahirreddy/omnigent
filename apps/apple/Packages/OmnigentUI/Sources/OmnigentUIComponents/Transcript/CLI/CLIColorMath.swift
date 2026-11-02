import SwiftUI

/// A gamma-encoded sRGB (or Display P3) color with WCAG luminance and contrast, for deriving
/// CLI colors that keep their contrast on every theme.
///
/// Only `Double`s are stored, so the palettes built from it have no padding bytes: SwiftUI
/// compares plain-data environment values bytewise, and garbage in padding made two equal
/// palettes differ, which re-rendered every view reading them in a loop.
nonisolated struct SRGB: Hashable, Sendable, CustomStringConvertible {
  var red: Double
  var green: Double
  var blue: Double
  /// 1 for Display P3, 0 for sRGB; a `Double` rather than a `Bool` to keep the layout dense.
  private var displayP3: Double = 0

  /// The components are Display P3 (terminal colors measured from a P3 screenshot).
  var isDisplayP3: Bool {
    get { displayP3 != 0 }
    set { displayP3 = newValue ? 1 : 0 }
  }

  static let white = Self(red: 1, green: 1, blue: 1)
  static let black = Self(red: 0, green: 0, blue: 0)

  init(red: Double, green: Double, blue: Double, isDisplayP3: Bool = false) {
    self.red = min(max(red, 0), 1)
    self.green = min(max(green, 0), 1)
    self.blue = min(max(blue, 0), 1)
    self.isDisplayP3 = isDisplayP3
  }

  /// A 24-bit `0xRRGGBB` value.
  init(hex: UInt32, isDisplayP3: Bool = false) {
    self.init(
      red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255, isDisplayP3: isDisplayP3)
  }

  /// A SwiftUI color, resolved without an environment (theme palettes are plain sRGB).
  init(_ color: Color) {
    let resolved = color.resolve(in: EnvironmentValues())
    self.init(
      red: Double(resolved.red), green: Double(resolved.green), blue: Double(resolved.blue))
  }

  var color: Color {
    Color(isDisplayP3 ? .displayP3 : .sRGB, red: red, green: green, blue: blue)
  }

  /// `#rrggbb`.
  var description: String {
    let channels = [red, green, blue].map { Int(($0 * 255).rounded()) }
    return "#"
      + channels.map { value in
        let digits = String(value, radix: 16)
        return digits.count == 1 ? "0" + digits : digits
      }.joined()
  }

  /// WCAG relative luminance.
  var luminance: Double {
    func linear(_ channel: Double) -> Double {
      channel <= 0.040_45 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }
    // Display P3 shares the sRGB transfer curve; only the primaries' weights differ.
    if isDisplayP3 {
      return 0.2290 * linear(red) + 0.6917 * linear(green) + 0.0793 * linear(blue)
    }
    return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
  }

  var isDark: Bool { luminance < 0.18 }

  /// The WCAG contrast ratio between two colors, 1 to 21.
  static func contrast(_ first: Self, _ second: Self) -> Double {
    let lighter = max(first.luminance, second.luminance)
    let darker = min(first.luminance, second.luminance)
    return (lighter + 0.05) / (darker + 0.05)
  }

  /// This color moved `amount` (0 to 1) of the way to `other`.
  func mixed(with other: Self, by amount: Double) -> Self {
    let weight = min(max(amount, 0), 1)
    return Self(
      red: red + (other.red - red) * weight, green: green + (other.green - green) * weight,
      blue: blue + (other.blue - blue) * weight, isDisplayP3: isDisplayP3)
  }

  /// The closest color to this one, moving its lightness away from `backgrounds`, that reaches
  /// `minimum` contrast against every one of them. The hue stays; only lightness changes.
  func ensuringContrast(_ minimum: Double, against backgrounds: [Self]) -> Self {
    func passes(_ color: Self) -> Bool {
      backgrounds.allSatisfy { Self.contrast(color, $0) >= minimum }
    }
    guard !passes(self) else { return self }
    let brightest = backgrounds.map(\.luminance).max() ?? 0
    // Lighten on dark backgrounds and darken on light ones; try the other way if that fails.
    let preferred: Self = brightest < 0.18 ? .white : .black
    for target in [preferred, preferred == .white ? Self.black : .white] {
      var step = 0.02
      while step <= 1 {
        let candidate = mixed(with: target, by: step)
        if passes(candidate) { return candidate }
        step += 0.02
      }
    }
    return preferred
  }
}

extension CLIPalette {
  /// The environment's default, computed once: a default rebuilt on every read is a new value
  /// to SwiftUI each time.
  static let fallback = Self(theme: .omni, dark: true, increasedContrast: false)
}
