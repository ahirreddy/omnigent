import SwiftUI
import Testing

@testable import OmnigentUIComponents

#if os(macOS)
  import AppKit
#endif

/// Text on the composer's tinted glass, over the bare canvas and over dense transcript text, for
/// every palette, light and dark, standard and Increase Contrast.
@Suite("Glass contrast")
struct GlassContrastTests {
  typealias Variant = ThemeContrastTests.Variant

  @Test("primary and muted text read on glass")
  func text() {
    for variant in ThemeContrastTests.variants {
      let primary: SRGB = variant.scheme == .dark ? .white : .black
      let muted = variant.resolve(.mutedText)
      for background in ThemeContrast.glass(variant.key) {
        // A mid-tone Custom canvas can't reach the minimum with any text.
        let strongest = SRGB.contrast(primary, background)
        let minimum = min(variant.textMinimum, strongest - 0.01)
        #expect(SRGB.contrast(primary, background) >= minimum, "\(variant) primary")
        let ratio = SRGB.contrast(muted, background)
        #expect(ratio >= minimum, "\(variant) muted on \(background): \(ratio)")
      }
    }
  }

  @Test("Increase Contrast tints the glass nearly opaque")
  func increasedTint() {
    #expect(GlassStyle.tintOpacity(increased: true) >= 0.8)
    #expect(GlassStyle.tintOpacity(increased: false) < GlassStyle.tintOpacity(increased: true))
  }
}

#if os(macOS)
  /// ``GlassSurface`` under Reduce Transparency: the theme's opaque surface, whatever is beneath.
  @Suite("Glass surface")
  struct GlassSurfaceRenderTests {
    @Test("Reduce Transparency draws the opaque theme surface over dark content")
    func reduceTransparencyIsSolid() throws {
      for scheme in [ColorScheme.light, .dark] {
        var environment = EnvironmentValues()
        environment.colorScheme = scheme
        let surface = ThemeColor.surface.resolve(in: environment).resolve(in: environment)
        let card = Color.clear.frame(width: 120, height: 60)
          .glassSurface(in: RoundedRectangle(cornerRadius: 12))
          .padding(20)
          .background(Color.black)
          .environment(\._accessibilityReduceTransparency, true)
        let rendered = try RenderSupport.render(
          card, width: 160, height: 100, scheme: scheme, layout: .regular)
        try RenderSupport.write(rendered, name: "glass-reduce-transparency-\(scheme)")
        let center = rendered.image.colorAt(
          x: rendered.image.pixelsWide / 2, y: rendered.image.pixelsHigh / 2)?
          .usingColorSpace(.sRGB)
        let pixel = try #require(center)
        // Within display-conversion rounding of the surface; black would show through glass.
        #expect(abs(pixel.redComponent - CGFloat(surface.red)) < 0.05, "\(scheme)")
        #expect(abs(pixel.greenComponent - CGFloat(surface.green)) < 0.05, "\(scheme)")
        #expect(abs(pixel.blueComponent - CGFloat(surface.blue)) < 0.05, "\(scheme)")
      }
    }
  }
#endif
