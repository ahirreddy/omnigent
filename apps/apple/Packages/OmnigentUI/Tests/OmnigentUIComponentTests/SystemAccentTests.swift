import Foundation
import SwiftUI
import Testing

@testable import OmnigentUIComponents

#if os(macOS)
  import AppKit
  @testable import OmnigentUITestSupport
#endif

/// Use system accent: off by default, stored under the app's own key, cleared by Reset, and a
/// theme that swaps in the system's accent while keeping its own "needs you" and links.
@Suite("Use system accent")
@MainActor
struct SystemAccentPreferenceTests {
  @Test("off by default, stored as a Boolean, read back, and cleared by Reset")
  func storage() throws {
    let store = try #require(UserDefaults(suiteName: "system-accent-\(UUID())"))
    let key = ThemePreferences.systemAccentKey
    let preferences = ThemePreferences(defaults: store)
    #expect(!preferences.usesSystemAccent)
    #expect(store.object(forKey: key) == nil)
    preferences.usesSystemAccent = true
    #expect(store.object(forKey: key) as? Bool == true)
    #expect(ThemePreferences(defaults: store).usesSystemAccent)
    // Not a web setting: a settings file never carries it.
    #expect(!SettingsPortability.exportableKeys.contains(key))
    SettingsPortability.resetAppearance(store)
    preferences.reload(from: store)
    #expect(!preferences.usesSystemAccent)
    #expect(preferences.readErrors.isEmpty)
  }

  @Test("a stored value that isn't a Boolean is reported and reads as off")
  func malformed() throws {
    let store = try #require(UserDefaults(suiteName: "system-accent-\(UUID())"))
    store.set("yes", forKey: ThemePreferences.systemAccentKey)
    let preferences = ThemePreferences(defaults: store)
    #expect(!preferences.usesSystemAccent)
    #expect(preferences.readErrors == [.malformed(key: ThemePreferences.systemAccentKey)])
  }

  @Test("the system accent replaces the theme's accent and selection, not its needs-you or links")
  func theme() {
    let theme = OmnigentTheme.omni.withSystemAccent()
    for (swapped, original) in [
      (theme.light, OmnigentTheme.omni.light), (theme.dark, OmnigentTheme.omni.dark),
    ] {
      #expect(swapped.accent == OmnigentTheme.systemAccent)
      #expect(swapped.selection != original.selection)
      #expect(swapped.brandAccent == original.brandAccent)
      #expect(swapped.link == original.link)
      #expect(swapped.canvas == original.canvas)
    }
  }
}

#if os(macOS)
  /// A checkbox and the primary button draw in one accent: the theme's by default, the
  /// system's under Use system accent, through the window root's ``omnigentAppearance(_:)``.
  @Suite("Use system accent: controls and the primary button share it", .serialized)
  @MainActor
  struct SystemAccentRenderTests {
    /// The theme's pink (`#DF3C85`) as a hue from 0 to 1.
    private static let themeHue = 333.0 / 360

    private func appearance(systemAccent: Bool) throws -> ThemePreferences {
      let store = try #require(UserDefaults(suiteName: "system-accent-render-\(UUID())"))
      let preferences = ThemePreferences(defaults: store)
      preferences.usesSystemAccent = systemAccent
      return preferences
    }

    /// The mean hue of the strongly colored pixels `view` draws, or `nil` when it draws none.
    private func hue(_ view: some View, systemAccent: Bool) throws -> Double? {
      let themed = view.padding(8).omnigentAppearance(try appearance(systemAccent: systemAccent))
      let rendered = try RenderSupport.render(
        themed, width: 220, height: 64, scheme: .light, layout: .regular)
      guard let pixels = RenderSupport.Pixels(rendered.image) else { return nil }
      var sine = 0.0
      var cosine = 0.0
      var count = 0
      for row in 0..<pixels.height {
        for column in 0..<pixels.width {
          let color = RenderSupport.Pixels.hsb(pixels.color(column, row))
          guard color.saturation > 0.45, color.brightness > 0.35 else { continue }
          sine += sin(color.hue * 2 * .pi)
          cosine += cos(color.hue * 2 * .pi)
          count += 1
        }
      }
      guard count > 0 else { return nil }
      let angle = atan2(sine, cosine) / (2 * .pi)
      return angle < 0 ? angle + 1 : angle
    }

    private func distance(_ first: Double, _ second: Double) -> Double {
      let gap = abs(first - second)
      return min(gap, 1 - gap)
    }

    private var checkbox: some View {
      OptionRow(
        option: FormOption(value: "Mac"), isMultiple: true, isSelected: true, action: {})
    }

    private var submit: some View {
      Button("Submit") {}.primaryActionStyle().controlSize(.large)
    }

    /// The system's accent as a hue, as the render draws it.
    private var systemHue: Double {
      let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .controlAccentColor
      return Double(accent.hueComponent)
    }

    @Test("under the theme, a chosen checkbox and Submit are both its pink")
    func themeAccent() throws {
      let box = try #require(try hue(checkbox, systemAccent: false), "the checkbox drew no color")
      let button = try #require(try hue(submit, systemAccent: false), "Submit drew no color")
      #expect(distance(box, button) < 0.04, "checkbox \(box), Submit \(button)")
      #expect(distance(box, Self.themeHue) < 0.05, "checkbox \(box)")
    }

    @Test("under Use system accent, both take the system's accent")
    func systemAccent() throws {
      let box = try #require(try hue(checkbox, systemAccent: true), "the checkbox drew no color")
      let button = try #require(try hue(submit, systemAccent: true), "Submit drew no color")
      #expect(distance(box, button) < 0.04, "checkbox \(box), Submit \(button)")
      #expect(distance(box, systemHue) < 0.05, "checkbox \(box), system \(systemHue)")
    }

    /// An AppKit checkbox draws grey in a window that is not key, as an offscreen one is, so a
    /// plain prominent button stands for the system controls the root's tint reaches.
    @Test("a plain prominent button follows the root's tint too")
    func systemControls() throws {
      let prominent = Button("Done") {}.buttonStyle(.borderedProminent)
      for systemAccent in [false, true] {
        let expected = systemAccent ? systemHue : Self.themeHue
        let button = try hue(prominent, systemAccent: systemAccent)
        #expect(
          button.map { distance($0, expected) < 0.06 } == true,
          "button \(String(describing: button))")
      }
    }
  }
#endif
