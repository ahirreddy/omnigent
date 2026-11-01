import SwiftUI
import Testing

@testable import OmnigentUIComponents

@Suite("Themes")
struct ThemeTests {
  @Test("theme colors resolve from the environment's theme and color scheme")
  func resolution() {
    var environment = EnvironmentValues()
    environment.omnigentTheme = PreviewData.sampleTheme
    environment.colorScheme = .light
    let light = ThemeColor.accent.resolve(in: environment).resolve(in: environment)
    environment.colorScheme = .dark
    let dark = ThemeColor.accent.resolve(in: environment).resolve(in: environment)
    #expect(light != dark)
    environment.omnigentTheme = .standard
    let standardDark = ThemeColor.accent.resolve(in: environment).resolve(in: environment)
    #expect(standardDark != dark)
  }

  @Test("opacity multiplies and roles survive")
  func opacity() {
    let faded = ThemeColor.failure.opacity(0.5).opacity(0.5)
    #expect(faded.alpha == 0.25)
    #expect(faded.role == ThemeColor.failure.role)
  }

  @Test("unknown stored ids fall back to the standard theme")
  func lookup() {
    #expect(OmnigentTheme.named("does-not-exist") == .standard)
    #expect(OmnigentTheme.named(OmnigentTheme.standard.id) == .standard)
    #expect(AppearancePreference.system.colorScheme == nil)
    #expect(AppearancePreference.dark.colorScheme == .dark)
  }

  #if os(macOS)
    @Test("switching the theme restyles a rendered card")
    func rendersPerTheme() throws {
      let card = DecisionCardView(card: PreviewData.codexCommand, respond: { _ in })
      let standard = try RenderSupport.render(
        card.omnigentTheme(.standard), width: 600, scheme: .light, layout: .regular)
      let sample = try RenderSupport.render(
        card.omnigentTheme(PreviewData.sampleTheme), width: 600, scheme: .light, layout: .regular)
      #expect(standard.image.tiffRepresentation != sample.image.tiffRepresentation)
      try RenderSupport.write(sample, name: "ui-theme-sample-light")
    }
  #endif
}
