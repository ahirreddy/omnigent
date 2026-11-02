import Foundation
import SwiftUI
import Testing

@testable import OmnigentUIComponents

@Suite("CLI style: preferences, colors, layout and source tinting")
struct CLIStyleTests {
  private func scratchDefaults() throws -> UserDefaults {
    let name = "cli-style-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  // MARK: Preferences

  @Test(
    "defaults: chat style, reading width and rich output for chat, edge to edge and plain for CLI")
  func preferenceDefaults() throws {
    let preferences = TranscriptPreferences(defaults: try scratchDefaults())
    #expect(preferences.style == .chat)
    #expect(preferences.contentWidth(for: .chat) == .reading)
    #expect(preferences.contentWidth(for: .cli) == .edgeToEdge)
    #expect(preferences.outputRendering(for: .chat) == .rich)
    #expect(preferences.outputRendering(for: .cli) == .plain)
    #expect(preferences.fontSize == TranscriptAppearance.defaultFontSize)
    #expect(preferences.readErrors.isEmpty)
  }

  @Test("style, per-style width and rendering, and font size persist and reload")
  func preferencePersistence() throws {
    let defaults = try scratchDefaults()
    let preferences = TranscriptPreferences(defaults: defaults)
    preferences.style = .cli
    preferences.outputRendering = .styled
    preferences.contentWidth = .wide
    preferences.setOutputRendering(.plain, for: .chat)
    preferences.fontSize = 15
    #expect(defaults.string(forKey: TranscriptPreferences.styleKey) == "cli")
    #expect(defaults.string(forKey: "omnigent:cli-output-rendering") == "styled")
    #expect(defaults.string(forKey: "omnigent:cli-content-width") == "wide")

    let reloaded = TranscriptPreferences(defaults: defaults)
    #expect(reloaded.style == .cli)
    #expect(reloaded.outputRendering == .styled)
    #expect(reloaded.contentWidth == .wide)
    #expect(reloaded.outputRendering(for: .chat) == .plain)
    #expect(reloaded.contentWidth(for: .chat) == .reading)
    #expect(reloaded.fontSize == 15)
    #expect(
      reloaded.appearance(style: .chat)
        == TranscriptAppearance(
          style: .chat, contentWidth: .reading, outputRendering: .plain, fontSize: 15))
  }

  @Test("malformed stored values fall back to defaults and are reported")
  func preferenceReadErrors() throws {
    let defaults = try scratchDefaults()
    defaults.set("terminal", forKey: TranscriptPreferences.styleKey)
    defaults.set("huge", forKey: TranscriptPreferences.widthKey(.cli))
    defaults.set(99.0, forKey: TranscriptPreferences.fontSizeKey)
    let preferences = TranscriptPreferences(defaults: defaults)
    #expect(preferences.style == .chat)
    #expect(preferences.contentWidth(for: .cli) == .edgeToEdge)
    #expect(preferences.fontSize == TranscriptAppearance.defaultFontSize)
    #expect(
      Set(preferences.readErrors.map(\.description))
        == Set(
          [
            TranscriptPreferences.styleKey, TranscriptPreferences.widthKey(.cli),
            TranscriptPreferences.fontSizeKey,
          ].map { ThemePreferences.ReadError.malformed(key: $0).description }))
  }

  @Test("the theme preferences carry the transcript preferences in the same store")
  func themePreferencesShareTheStore() throws {
    let defaults = try scratchDefaults()
    ThemePreferences(defaults: defaults).transcript.style = .cli
    #expect(ThemePreferences(defaults: defaults).transcript.style == .cli)
  }

  @Test("the appearance clamps the font size")
  func fontSizeClamp() {
    #expect(TranscriptAppearance(fontSize: 2).fontSize == TranscriptAppearance.fontSizes.lowerBound)
    #expect(
      TranscriptAppearance(fontSize: 80).fontSize == TranscriptAppearance.fontSizes.upperBound)
  }

  @Test("window controls stay equal across updates and write the window's style")
  @MainActor
  func windowControlsAreStable() throws {
    let preferences = TranscriptPreferences(defaults: try scratchDefaults())
    let store = TranscriptWindowStyleStore()
    var stored = "unset"
    store.storage = Binding(get: { stored }, set: { stored = $0 })
    // A new value each update, as the host makes, compares equal to the last one.
    let first = TranscriptWindowControls(style: .chat, preferences: preferences, window: store)
    let second = TranscriptWindowControls(style: .chat, preferences: preferences, window: store)
    #expect(first == second)
    let otherWindow = TranscriptWindowControls(
      style: .chat, preferences: preferences, window: TranscriptWindowStyleStore())
    #expect(first != otherWindow)
    #expect(first != TranscriptWindowControls(style: .cli, preferences: preferences, window: store))

    first.setStyle(.cli)
    #expect(stored == "cli")
    // Choosing the device's style clears the window's own choice.
    first.setStyle(.chat)
    #expect(stored.isEmpty)
  }

  @Test("the Appearance action stays equal for one scene and opens its settings")
  @MainActor
  func appearanceActionIsStable() {
    let presenter = AppearanceSettingsPresenter()
    var opened = 0
    presenter.open = { opened += 1 }
    let action = OpenAppearanceSettingsAction(presenter: presenter)
    #expect(action == OpenAppearanceSettingsAction(presenter: presenter))
    #expect(action != OpenAppearanceSettingsAction(presenter: AppearanceSettingsPresenter()))
    action()
    #expect(opened == 1)
  }

  @Test("environment values are dense plain data, so equal values are equal bytes")
  func environmentValuesHaveNoPadding() {
    // SwiftUI compares plain-data environment values bytewise; padding made equal palettes
    // differ and re-rendered their readers in a loop.
    #expect(MemoryLayout<SRGB>.size == 4 * MemoryLayout<Double>.size)
    #expect(MemoryLayout<CLIPalette>.size.isMultiple(of: MemoryLayout<SRGB>.size))
    #expect(MemoryLayout<TranscriptAppearance>.size == MemoryLayout<Double>.size + 3)
    // The default is one stored value, not a palette derived again on every read.
    #expect(EnvironmentValues().cliPalette == CLIPalette.fallback)
  }

  // MARK: Colors

  private static var allThemes: [OmnigentTheme] {
    OmnigentTheme.builtIn + [
      CustomTheme.default.theme(),
      CustomTheme(
        basePalette: "nord", accent: "#f4e04d", darkAccent: "#20304a", tint: "#9a9a9a",
        darkTint: "#5a5a5a", contrast: 0, translucentSidebar: false
      ).theme(),
    ]
  }

  @Test(
    "every text role reaches WCAG AA in every palette, light and dark, and AAA with Increase Contrast"
  )
  func contrast() {
    for theme in Self.allThemes {
      for dark in [false, true] {
        for increased in [false, true] {
          let palette = CLIPalette(theme: theme, dark: dark, increasedContrast: increased)
          let minimum = CLIPalette.textMinimum(increased: increased)
          for role in palette.textRoles {
            for background in role.backgrounds {
              let ratio = SRGB.contrast(role.color, background)
              #expect(
                ratio >= minimum - 0.01,
                "\(theme.id) \(dark ? "dark" : "light")\(increased ? " increased" : "") \(role.name) \(role.color) on \(background): \(ratio)"
              )
            }
          }
          #expect(
            SRGB.contrast(palette.body, palette.canvas)
              >= CLIPalette.bodyMinimum(increased: increased) - 0.01)
          let graphic = increased ? 4.5 : 3
          #expect(SRGB.contrast(palette.prompt, palette.band) >= graphic - 0.01, "\(theme.id)")
          #expect(SRGB.contrast(palette.bullet, palette.canvas) >= graphic - 0.01, "\(theme.id)")
          #expect(SRGB.contrast(palette.band, palette.canvas) > 1.1, "\(theme.id) band")
        }
      }
    }
  }

  @Test("Nord dark matches the reference screenshot's canvas and band")
  func nordMatchesReference() {
    let palette = CLIPalette(theme: .nord, dark: true, increasedContrast: false)
    #expect(palette.canvas.description == "#0e2a35")
    #expect(palette.canvas.isDisplayP3)
    let measured = SRGB(hex: 0x314B55, isDisplayP3: true)
    #expect(abs(palette.band.red - measured.red) < 0.03)
    #expect(abs(palette.band.green - measured.green) < 0.03)
    #expect(abs(palette.band.blue - measured.blue) < 0.03)
    #expect(palette.heading.description == "#efb68e")
    #expect(palette.code.description == "#b3e1a7")
    #expect(palette.link.description == "#92b3f4")
  }

  @Test("contrast adjustment keeps hue and only moves lightness")
  func ensuringContrast() {
    let canvas = SRGB(hex: 0xFFFFFF)
    let pale = SRGB(hex: 0xFFE680)
    let adjusted = pale.ensuringContrast(4.5, against: [canvas])
    #expect(SRGB.contrast(adjusted, canvas) >= 4.5)
    #expect(adjusted.red >= adjusted.green && adjusted.green >= adjusted.blue)
    #expect(SRGB(hex: 0x000000).ensuringContrast(4.5, against: [canvas]) == SRGB(hex: 0x000000))
  }

  // MARK: Layout

  private func rows() -> [Row] {
    [
      Row(id: "u1", role: .user, text: "hi"),
      Row(id: "a1", role: .assistant, text: "Got it.", responseId: "r1"),
      Row(id: "u2", role: .user, text: "again"),
      Row(id: "a2", role: .assistant, text: "Working", isStreaming: true, responseId: "r2"),
    ]
  }

  @Test("a footer follows each settled turn, never the live one")
  func footers() {
    let segments = TurnLayout.segments(TranscriptLayout.items(for: rows()), isRunning: true)
    let finished = Date(timeIntervalSince1970: 1_000)
    let blocks = CLILayout.blocks(
      segments, durations: ["r1": 12, "r2": 3], timestamps: ["a1": finished], isRunning: true,
      now: finished)
    let footers = blocks.compactMap { block -> String? in
      if case .footer(_, let text) = block { return text }
      return nil
    }
    #expect(
      footers == ["Worked for 12s \u{2022} \(MessageTimestamp.format(finished, now: finished))"])
    #expect(blocks.last.map { if case .segment = $0 { true } else { false } } == true)
  }

  @Test("a turn with neither duration nor time has no footer")
  func noFooter() {
    let segments = TurnLayout.segments(
      TranscriptLayout.items(for: Array(rows().prefix(2))), isRunning: false)
    let blocks = CLILayout.blocks(segments, durations: [:], timestamps: [:], isRunning: false)
    #expect(blocks.count == 2)
  }

  // MARK: Plain and Styled text

  @Test("Plain tints markdown syntax through the shared parser without changing a character")
  func sourceTinting() {
    let source = "## Head\n\nSome **bold**, *it*, `code` and [a link](https://example.com).\n"
    let spans = SourceTinting.spans(in: source)
    func text(_ tint: SourceTint) -> [String] {
      spans.filter { $0.tint == tint }.map { span in
        let utf8 = source.utf8
        let lower = utf8.index(utf8.startIndex, offsetBy: span.range.lowerBound)
        let upper = utf8.index(utf8.startIndex, offsetBy: span.range.upperBound)
        return String(source[lower..<upper])
      }
    }
    #expect(text(.heading) == ["## Head"])
    #expect(text(.bold) == ["**bold**"])
    #expect(text(.italic) == ["*it*"])
    #expect(text(.code) == ["`code`"])
    #expect(text(.link) == ["[a link](https://example.com)"])
    let palette = CLIPalette(theme: .nord, dark: true, increasedContrast: false)
    let attributed = SourceTinting.attributed(source, spans: spans, palette: palette, cursor: false)
    #expect(String(attributed.characters) == source)
    let streaming = SourceTinting.attributed(source, spans: spans, palette: palette, cursor: true)
    #expect(String(streaming.characters) == source + CLICursor.glyph)
  }

  @Test("Plain keeps multi-byte text and unfinished markdown intact")
  func sourceTintingUnicode() {
    let source = "## Caf\u{00E9} \u{1F600}\n\n**unfinished `code"
    let spans = SourceTinting.spans(in: source)
    let palette = CLIPalette(theme: .github, dark: false, increasedContrast: false)
    let attributed = SourceTinting.attributed(source, spans: spans, palette: palette, cursor: false)
    #expect(String(attributed.characters) == source)
  }

  @Test("Styled links show their URL in parentheses unless the text is the URL")
  func styledLinks() throws {
    let palette = CLIPalette(theme: .nord, dark: true, increasedContrast: false)
    let blocks = MarkdownParser.parse("[A link](https://example.com) and https://example.org")
    guard case .paragraph(let text) = try #require(blocks.first) else {
      Issue.record("expected a paragraph")
      return
    }
    let styled = CLIInline.styled(text, palette: palette)
    #expect(String(styled.characters) == "A link (https://example.com) and https://example.org")
  }
}
