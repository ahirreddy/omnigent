import Foundation
import Observation
import SwiftUI

/// Which appearances the canvas shows.
enum CatalogAppearance: String, CaseIterable, Identifiable, Sendable {
  case light
  case dark
  case both

  var id: Self { self }

  var title: String {
    switch self {
    case .light: "Light"
    case .dark: "Dark"
    case .both: "Both"
    }
  }

  var schemes: [ColorScheme] {
    switch self {
    case .light: [.light]
    case .dark: [.dark]
    case .both: [.light, .dark]
    }
  }
}

/// Everything that decides how one render looks. The live canvas and the snapshot exporter
/// apply the same traits.
struct CatalogTraits: Hashable {
  var theme: OmnigentTheme
  var scheme: ColorScheme
  var screen: CatalogScreen
  var dynamicType: DynamicTypeSize = .large
  var increaseContrast = false
  var reduceTransparency = false
  var reduceMotion = false
  var rightToLeft = false

  /// A file-name-safe suffix naming the non-default traits.
  var fileSuffix: String {
    var parts = [theme.id, scheme == .dark ? "dark" : "light"]
    if dynamicType != .large { parts.append("type-\(Self.name(dynamicType))") }
    if increaseContrast { parts.append("contrast") }
    if reduceTransparency { parts.append("reduced-transparency") }
    if reduceMotion { parts.append("reduced-motion") }
    if rightToLeft { parts.append("rtl") }
    return parts.joined(separator: "-")
  }

  static func name(_ size: DynamicTypeSize) -> String {
    names[size] ?? "unknown"
  }

  private static let names: [DynamicTypeSize: String] = [
    .xSmall: "xs", .small: "s", .medium: "m", .large: "l", .xLarge: "xl", .xxLarge: "xxl",
    .xxxLarge: "xxxl", .accessibility1: "ax1", .accessibility2: "ax2", .accessibility3: "ax3",
    .accessibility4: "ax4", .accessibility5: "ax5",
  ]

}

extension View {
  /// Applies `traits` to a catalog canvas: theme, color scheme, Dynamic Type, contrast, motion,
  /// layout direction, and the screen's size classes, display scale, layout width, composer
  /// style and hinge posture.
  func catalogTraits(_ traits: CatalogTraits) -> some View {
    environment(\.omnigentTheme, traits.theme)
      .environment(\.colorScheme, traits.scheme)
      .environment(\.dynamicTypeSize, traits.dynamicType)
      // The public keys are read-only; these are the settable ones previews use.
      .environment(\._colorSchemeContrast, traits.increaseContrast ? .increased : .standard)
      .environment(\._accessibilityReduceTransparency, traits.reduceTransparency)
      .environment(\._accessibilityReduceMotion, traits.reduceMotion)
      .environment(\.layoutDirection, traits.rightToLeft ? .rightToLeft : .leftToRight)
      .environment(\.layoutWidth, traits.screen.layoutWidth)
      .environment(\.horizontalSizeClass, traits.screen.horizontalSizeClass)
      .environment(\.verticalSizeClass, traits.screen.verticalSizeClass)
      .environment(\.displayScale, traits.screen.displayScale)
      .environment(\.composerLayoutStyle, traits.screen.composerStyle)
      .environment(\.hingePosture, traits.screen.hingePosture)
  }
}

/// The inspector's global controls, shared by every canvas in a catalog window.
@Observable
final class CatalogSettings {
  var appearance: CatalogAppearance = .light
  var device = CatalogDevice.platformDefault
  var isLandscape = false
  var isUnfolded = false
  /// Draw iPhone, iPad and fold pages in their device frame, with the hardware's safe areas.
  var showsFrame = true
  var dynamicType: DynamicTypeSize = .large
  var increaseContrast = false
  var reduceTransparency = false
  var reduceMotion = false
  var rightToLeft = false
  /// Scale whole pages down to fit the window instead of scrolling at actual size.
  var fitsPages = true
  /// Show a component's states side by side instead of one at a time.
  var showsAllStates = true
  /// The palette, in a scratch defaults suite so the gallery never changes the app's theme.
  let preferences: ThemePreferences

  init(preferences: ThemePreferences = ThemePreferences(defaults: CatalogSettings.scratchDefaults))
  {
    self.preferences = preferences
    // The catalog decides the color scheme per canvas; the stored mode must not override it.
    preferences.mode = .system
  }

  /// The scratch suite. `UserDefaults(suiteName:)` fails only for the app's own bundle id or
  /// the global domain, and this is neither.
  static var scratchDefaults: UserDefaults {
    UserDefaults(suiteName: "ai.omnigent.gallery") ?? UserDefaults()
  }

  /// The chosen device in the chosen posture.
  var screen: CatalogScreen {
    CatalogScreen(device, landscape: isLandscape, unfolded: isUnfolded)
  }

  func context(_ screen: CatalogScreen) -> CatalogContext {
    CatalogContext(screen: screen, preferences: preferences)
  }

  func traits(_ scheme: ColorScheme, screen: CatalogScreen) -> CatalogTraits {
    CatalogTraits(
      theme: preferences.theme, scheme: scheme, screen: screen, dynamicType: dynamicType,
      increaseContrast: increaseContrast, reduceTransparency: reduceTransparency,
      reduceMotion: reduceMotion, rightToLeft: rightToLeft)
  }

  /// The screen a canvas uses: the chosen device when the entry supports it, else the entry's
  /// first, in the chosen posture where that device has it.
  func screen(for canvas: CatalogCanvas) -> CatalogScreen {
    let devices = canvas.devices
    let device = devices.isEmpty || devices.contains(device) ? device : devices[0]
    return CatalogScreen(device, landscape: isLandscape, unfolded: isUnfolded)
  }
}
