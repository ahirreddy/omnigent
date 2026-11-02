import SwiftUI
import Synchronization

/// Contrast-safe forms of the theme's brand colors. Each starts from the palette's color and
/// moves only its lightness until it reaches WCAG AA (AAA under Increase Contrast) on every
/// surface it is drawn on, so no palette, light or dark, yields unreadable text or labels.
nonisolated enum ThemeContrast {
  /// What a role is computed for: one palette in one scheme and contrast setting.
  struct Key: Hashable, Sendable {
    let palette: ThemePalette
    let dark: Bool
    let increased: Bool
  }

  /// The derived colors for one ``Key``.
  struct Roles: Hashable, Sendable {
    /// The primary action's fill and its label.
    let primaryFill: SRGB
    let onPrimary: SRGB
    /// "Needs you" text and glyphs, legible on the canvas, the sidebar and their own capsule.
    let attention: SRGB
    /// How much of ``attention`` tints its capsule.
    let capsuleOpacity: Double
    /// Secondary text, legible on the canvas, the sidebar and a selected row.
    let mutedText: SRGB
    /// How much of the accent tints a selected row.
    let rowSelectionOpacity: Double
  }

  /// The tints a "needs you" capsule may lay under its text, strongest first. Light text on a
  /// dark theme lightens its own capsule, so a fainter tint keeps it legible.
  static let capsuleOpacities = [0.15, 0.12, 0.09, 0.06]

  private static let cache = Mutex<[Key: Roles]>([:])

  /// The roles for `key`, computed once per palette, scheme and contrast setting.
  static func roles(_ key: Key) -> Roles {
    if let cached = cache.withLock({ $0[key] }) { return cached }
    let roles = derive(key)
    cache.withLock { entries in
      // Only an edited Custom theme adds keys; start over rather than grow without bound.
      if entries.count > 64 { entries.removeAll() }
      entries[key] = roles
    }
    return roles
  }

  /// The roles for the environment's theme, scheme and contrast setting.
  static func roles(in environment: EnvironmentValues) -> Roles {
    let dark = environment.colorScheme == .dark
    return roles(
      Key(
        palette: environment.omnigentTheme.palette(for: environment.colorScheme), dark: dark,
        increased: environment.colorSchemeContrast == .increased))
  }

  /// Minimum contrast for text: WCAG AA, or AAA under Increase Contrast.
  static func textMinimum(increased: Bool) -> Double {
    CLIPalette.textMinimum(increased: increased)
  }

  /// The surfaces text is drawn on: the canvas, a card, the sidebar (themed and system).
  static func surfaces(_ key: Key) -> [SRGB] {
    let palette = key.palette
    let canvas = palette.canvas.map { composite($0, over: .white) } ?? defaultCanvas(key.dark)
    let systemSidebar = defaultSidebar(key.dark)
    let sidebar = palette.sidebarTint.map { composite($0, over: systemSidebar) } ?? systemSidebar
    return [canvas, surface(canvas, dark: key.dark), systemSidebar, sidebar]
  }

  /// A selected sidebar row: the softened accent over the sidebar (``ThemeColor/rowSelection``).
  static func selectedRows(_ key: Key) -> [SRGB] {
    selectedRows(key, opacity: roles(key).rowSelectionOpacity)
  }

  private static func selectedRows(_ key: Key, opacity: Double) -> [SRGB] {
    surfaces(key)[2...].map { sidebar in
      sidebar.mixed(with: composite(key.palette.accent, over: sidebar), by: opacity)
    }
  }

  /// The selected row's tint: stronger under Increase Contrast, but never so strong that the
  /// row's text loses its minimum (with room for secondary text) on a light accent.
  static func rowSelectionOpacity(_ key: Key) -> Double {
    let strongest: SRGB = key.dark ? .white : .black
    let headroom = textMinimum(increased: key.increased) + 1
    var opacity = key.increased ? 0.24 : (key.dark ? 0.14 : 0.08)
    while opacity > 0.06,
      selectedRows(key, opacity: opacity).contains(where: {
        SRGB.contrast(strongest, $0) < headroom
      })
    {
      opacity -= 0.02
    }
    return opacity
  }

  /// The card surface over `canvas`, as ``ThemeColor/surface``.
  static func surface(_ canvas: SRGB, dark: Bool) -> SRGB {
    canvas.mixed(with: dark ? .white : .black, by: dark ? 0.06 : 0.025)
  }

  /// The "needs you" capsule's fill: the text color's tint over the opaque card surface.
  static func capsule(_ text: SRGB, key: Key, opacity: Double) -> SRGB {
    surface(surfaces(key)[0], dark: key.dark).mixed(with: text, by: opacity)
  }

  /// A fill for the primary action and its label that read at `minimum`: the accent, darkened
  /// as far as a white label needs. The Mac draws a prominent button's label white whatever its
  /// foreground style, so the fill, not the label, adapts.
  static func primaryAction(_ accent: SRGB, minimum: Double) -> (fill: SRGB, label: SRGB) {
    let fill = shift(accent, toward: .black, until: { SRGB.contrast(.white, $0) >= minimum })
    return (fill?.color ?? .black, .white)
  }

  /// `color` moved toward `target` in 2% steps until `passes`, with how far it moved.
  static func shift(_ color: SRGB, toward target: SRGB, until passes: (SRGB) -> Bool) -> (
    color: SRGB, amount: Double
  )? {
    var amount = 0.0
    while amount <= 1 {
      let candidate = color.mixed(with: target, by: amount)
      if passes(candidate) { return (candidate, amount) }
      amount += 0.02
    }
    return nil
  }

  /// The brand accent as "needs you" text, legible on every surface and on its own capsule,
  /// with the strongest capsule tint that allows it.
  static func attention(_ brand: SRGB, key: Key, minimum: Double) -> (
    color: SRGB, capsuleOpacity: Double
  ) {
    let surfaces = surfaces(key)
    var color = brand
    for opacity in capsuleOpacities {
      // The capsule's tint is the color itself, so settle the two together.
      color = brand
      for _ in 0..<6 {
        let backgrounds = surfaces + [capsule(color, key: key, opacity: opacity)]
        let next = brand.ensuringContrast(minimum, against: backgrounds)
        if next == color { break }
        color = next
      }
      let backgrounds = surfaces + [capsule(color, key: key, opacity: opacity)]
      if backgrounds.allSatisfy({ SRGB.contrast(color, $0) >= minimum }) {
        return (color, opacity)
      }
    }
    return (color, capsuleOpacities.last ?? 0)
  }

  private static func derive(_ key: Key) -> Roles {
    let minimum = textMinimum(increased: key.increased)
    let canvas = surfaces(key)[0]
    let primary = primaryAction(composite(key.palette.accent, over: canvas), minimum: minimum)
    let brand = composite(key.palette.brandAccent, over: canvas)
    let muted = SRGB(
      key.dark ? DesignTokens.darkMutedForeground : DesignTokens.lightMutedForeground)
    let selection = rowSelectionOpacity(key)
    let backgrounds = surfaces(key) + selectedRows(key, opacity: selection)
    let attention = attention(brand, key: key, minimum: minimum)
    return Roles(
      primaryFill: primary.fill, onPrimary: primary.label,
      attention: attention.color, capsuleOpacity: attention.capsuleOpacity,
      mutedText: muted.ensuringContrast(minimum, against: backgrounds),
      rowSelectionOpacity: selection)
  }

  /// The canvas when the theme keeps the system background.
  private static func defaultCanvas(_ dark: Bool) -> SRGB {
    dark ? SRGB(hex: 0x1E1E1E) : .white
  }

  /// The system sidebar: the lighter of the dark materials, the darker of the light ones.
  private static func defaultSidebar(_ dark: Bool) -> SRGB {
    dark ? SRGB(hex: 0x323236) : SRGB(hex: 0xE3E3E8)
  }

  /// `color` (which may be translucent) composited over `background`.
  static func composite(_ color: Color, over background: SRGB) -> SRGB {
    let resolved = color.resolve(in: EnvironmentValues())
    let opaque = SRGB(
      red: Double(resolved.red), green: Double(resolved.green), blue: Double(resolved.blue))
    return background.mixed(with: opaque, by: Double(resolved.opacity))
  }
}
