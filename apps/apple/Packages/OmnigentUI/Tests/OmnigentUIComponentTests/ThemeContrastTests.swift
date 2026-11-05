import SwiftUI
import Testing

@testable import OmnigentUIComponents

/// WCAG contrast of the theme's text and label roles, for every palette (the built-ins, the
/// default Custom and a hostile Custom), light and dark, standard and Increase Contrast.
@Suite("Theme contrast")
struct ThemeContrastTests {
  /// A Custom theme with a pale yellow accent and mid-tone canvases.
  static let hostile: OmnigentTheme = {
    var custom = CustomTheme.default
    custom.accent = "#f5e663"
    custom.darkAccent = "#7a7a7a"
    custom.tint = "#c8c8c8"
    custom.darkTint = "#4a4a4a"
    return custom.theme()
  }()

  static let themes = OmnigentTheme.builtIn + [CustomTheme.default.theme(), hostile]

  struct Variant: CustomStringConvertible {
    let theme: OmnigentTheme
    let scheme: ColorScheme
    let increased: Bool

    var description: String {
      "\(theme.id) \(scheme == .dark ? "dark" : "light")\(increased ? " increased" : "")"
    }

    var environment: EnvironmentValues {
      var environment = EnvironmentValues()
      environment.omnigentTheme = theme
      environment.colorScheme = scheme
      environment._colorSchemeContrast = increased ? .increased : .standard
      return environment
    }

    var key: ThemeContrast.Key {
      ThemeContrast.Key(
        palette: theme.palette(for: scheme), dark: scheme == .dark, increased: increased)
    }

    var textMinimum: Double { increased ? 7 : 4.5 }

    func resolve(_ color: ThemeColor) -> SRGB {
      let resolved = color.resolve(in: environment).resolve(in: environment)
      return SRGB(
        red: Double(resolved.red), green: Double(resolved.green), blue: Double(resolved.blue))
    }
  }

  static let variants: [Variant] = themes.flatMap { theme in
    [ColorScheme.light, .dark].flatMap { scheme in
      [false, true].map { Variant(theme: theme, scheme: scheme, increased: $0) }
    }
  }

  @Test("the primary action's label reads on its fill")
  func primaryLabel() {
    for variant in Self.variants {
      let ratio = SRGB.contrast(variant.resolve(.accent), variant.resolve(.onAccent))
      #expect(ratio >= variant.textMinimum, "\(variant): \(ratio)")
    }
  }

  @Test("needs-you text reads on the canvas, the sidebar and its capsule")
  func attentionText() {
    for variant in Self.variants {
      let key = variant.key
      let text = variant.resolve(.attention)
      let capsule = ThemeContrast.capsule(
        text, key: key, opacity: ThemeContrast.roles(key).capsuleOpacity)
      for background in ThemeContrast.surfaces(key) + [capsule] {
        // A mid-tone Custom canvas can't reach the minimum with any text.
        let strongest = SRGB.contrast(variant.scheme == .dark ? .white : .black, background)
        let ratio = SRGB.contrast(text, background)
        #expect(
          ratio >= min(variant.textMinimum, strongest - 0.01),
          "\(variant) on \(background): \(ratio)")
      }
    }
  }

  @Test("section headers and metadata read on the sidebar and a selected row")
  func mutedText() {
    for variant in Self.variants {
      let text = variant.resolve(.mutedText)
      let key = variant.key
      for surface in ThemeContrast.surfaces(key) + ThemeContrast.selectedRows(key) {
        // A mid-tone Custom canvas can't reach the minimum with any text; then muted text is as
        // strong as text gets.
        let strongest = SRGB.contrast(variant.scheme == .dark ? .white : .black, surface)
        let ratio = SRGB.contrast(text, surface)
        #expect(
          ratio >= min(variant.textMinimum, strongest - 0.01),
          "\(variant) on \(surface): \(ratio)")
      }
    }
  }

  @Test("the control tint reads as text on the canvas and the sidebar, and stays the accent")
  func controlTint() {
    for variant in Self.variants {
      let tint = variant.resolve(.controlTint)
      for surface in ThemeContrast.surfaces(variant.key) {
        let strongest = SRGB.contrast(variant.scheme == .dark ? .white : .black, surface)
        let ratio = SRGB.contrast(tint, surface)
        #expect(
          ratio >= min(variant.textMinimum, strongest - 0.01),
          "\(variant) on \(surface): \(ratio)")
      }
    }
    // Omnigent's pink darkens in light mode to read on the sidebar, and stays pink.
    let light = Variant(theme: .omni, scheme: .light, increased: false).resolve(.controlTint)
    #expect(light.luminance < SRGB(hex: 0xDF3C85).luminance)
    #expect(light.red > 0.6 && light.red > light.green * 2, "still pink: \(light)")
  }

  @Test("the Omnigent light pink darkens only as far as it must")
  func omniLight() {
    let variant = Variant(theme: .omni, scheme: .light, increased: false)
    let pink = SRGB(hex: 0xDF3C85)
    // The palette's own pink was 3.35:1 on its capsule and 4.10:1 under a white label.
    #expect(SRGB.contrast(pink, SRGB.white.mixed(with: pink, by: 0.15)) < 4.5)
    let attention = variant.resolve(.attention)
    #expect(attention.luminance < pink.luminance)
    #expect(attention.red > 0.6, "still pink: \(attention)")
    #expect(variant.resolve(.onAccent) == .white)
    let fill = variant.resolve(.accent)
    #expect(SRGB.contrast(fill, pink) < 1.3, "the fill stays near the brand: \(fill)")
  }

  @Test("light accents darken under their white label")
  func lightAccents() {
    let variant = Variant(theme: .catppuccin, scheme: .dark, increased: false)
    let accent = SRGB(OmnigentTheme.catppuccin.dark.accent)
    #expect(variant.resolve(.onAccent) == .white)
    #expect(variant.resolve(.accent).luminance < accent.luminance)
  }
}

#if os(macOS)
  import AppKit

  /// The rendered controls draw exactly the measured roles: the offscreen bitmap is not sRGB,
  /// so each control's pixels are compared with swatches of the role rendered beside it, and
  /// the contrast itself comes from ``ThemeContrastTests``.
  @Suite("Rendered roles", .serialized)
  @MainActor
  struct RenderedRoleTests {
    static func pixels(_ rendered: RenderSupport.Rendered) -> [SRGB] {
      let image = rendered.image
      return (0..<image.pixelsHigh).flatMap { row in
        (0..<image.pixelsWide).compactMap { column in
          image.colorAt(x: column, y: row).map {
            SRGB(red: $0.redComponent, green: $0.greenComponent, blue: $0.blueComponent)
          }
        }
      }
    }

    static func distance(_ first: SRGB, _ second: SRGB) -> Double {
      max(
        abs(first.red - second.red), abs(first.green - second.green),
        abs(first.blue - second.blue))
    }

    /// Renders `view` after swatches of `roles`, and returns each swatch's rendered color and
    /// the view's pixels.
    static func render(
      _ view: some View, roles: [AnyShapeStyle], theme: OmnigentTheme, scheme: ColorScheme,
      name: String
    ) throws -> (swatches: [SRGB], pixels: [SRGB]) {
      let swatches = HStack(spacing: 0) {
        ForEach(roles.indices, id: \.self) { index in
          Rectangle().fill(roles[index]).frame(width: 20, height: 20)
        }
      }
      let swatchImage = try RenderSupport.render(
        swatches.omnigentTheme(theme), width: CGFloat(roles.count * 20), scheme: scheme,
        layout: .regular)
      let image = swatchImage.image
      let scale = image.pixelsWide / (roles.count * 20)
      let colors = roles.indices.map { index in
        let color = image.colorAt(x: (index * 20 + 10) * scale, y: 10 * scale)
        return SRGB(
          red: Double(color?.redComponent ?? 0), green: Double(color?.greenComponent ?? 0),
          blue: Double(color?.blueComponent ?? 0))
      }
      let rendered = try RenderSupport.render(
        view.fixedSize().padding(4).omnigentTheme(theme).themeCanvas(), width: 160,
        scheme: scheme, layout: .regular)
      try RenderSupport.write(rendered, name: name)
      return (colors, pixels(rendered))
    }

    @Test("the primary button draws the accessible fill under a white label")
    func primaryButton() throws {
      for theme in OmnigentTheme.builtIn {
        for scheme in [ColorScheme.light, .dark] {
          let (swatches, pixels) = try Self.render(
            Button("Approve") {}.primaryActionStyle().controlSize(.large),
            roles: [AnyShapeStyle(ThemeColor.accent), AnyShapeStyle(ThemeColor.onAccent)],
            theme: theme, scheme: scheme, name: "role-approve-\(theme.id)-\(scheme)")
          let fill = pixels.filter { Self.distance($0, swatches[0]) < 0.01 }.count
          #expect(fill > pixels.count / 4, "\(theme.id) \(scheme): the fill isn't the accent")
          #expect(
            pixels.contains { Self.distance($0, swatches[1]) < 0.02 },
            "\(theme.id) \(scheme): no label in the label color")
        }
      }
    }

    @Test("the Needs you capsule draws its text in the attention color")
    func capsule() throws {
      for theme in OmnigentTheme.builtIn {
        for scheme in [ColorScheme.light, .dark] {
          let (swatches, pixels) = try Self.render(
            NeedsYouCapsule(requests: 2).scaleEffect(2).padding(12),
            roles: [AnyShapeStyle(ThemeColor.attention)], theme: theme, scheme: scheme,
            name: "role-capsule-\(theme.id)-\(scheme)")
          #expect(
            pixels.contains { Self.distance($0, swatches[0]) < 0.03 },
            "\(theme.id) \(scheme): no text in the attention color")
        }
      }
    }
  }
#endif
