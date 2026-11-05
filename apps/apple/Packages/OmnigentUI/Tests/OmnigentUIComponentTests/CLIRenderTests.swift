#if os(macOS)
  import AppKit
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("CLI style rendering", .serialized)
  struct CLIRenderTests {
    private struct ThemeCase {
      let name: String
      let theme: OmnigentTheme
      let scheme: ColorScheme
    }

    private static let themes = [
      ThemeCase(name: "nord", theme: .nord, scheme: .dark),
      ThemeCase(name: "omnigent-dark", theme: .omni, scheme: .dark),
      ThemeCase(name: "omnigent-light", theme: .omni, scheme: .light),
      ThemeCase(name: "github-light", theme: .github, scheme: .light),
    ]

    private func screen(
      _ scenario: CLIPreviewScenario, style: TranscriptStyle = .cli,
      rendering: OutputRendering = .styled, theme: OmnigentTheme = .nord
    ) -> some View {
      CLIPreviewScreen(scenario: scenario)
        .transcriptAppearance(TranscriptAppearance(style: style, outputRendering: rendering))
        .omnigentTheme(theme)
    }

    @Test("both styles render every scenario in every output rendering")
    func smoke() throws {
      for scenario in CLIPreviewScenario.allCases {
        for style in TranscriptStyle.allCases {
          for rendering in OutputRendering.allCases {
            let rendered = try RenderSupport.render(
              screen(scenario, style: style, rendering: rendering), width: 900, height: 900,
              scheme: .dark, layout: .regular)
            #expect(
              RenderSupport.inkCoverage(rendered) > 0.01,
              "\(scenario) \(style) \(rendering) rendered blank")
          }
        }
      }
    }

    /// The fraction of sampled pixels that differ between two renders of the same size.
    private func difference(_ first: RenderSupport.Rendered, _ second: RenderSupport.Rendered)
      -> Double
    {
      guard first.size == second.size else { return 1 }
      var differing = 0
      var samples = 0
      for row in stride(from: 0, to: first.image.pixelsHigh, by: 2) {
        for column in stride(from: 0, to: first.image.pixelsWide, by: 2) {
          samples += 1
          if first.image.colorAt(x: column, y: row) != second.image.colorAt(x: column, y: row) {
            differing += 1
          }
        }
      }
      return samples == 0 ? 0 : Double(differing) / Double(samples)
    }

    private func transcript(_ style: TranscriptStyle, actions: ConversationActions) -> some View {
      TranscriptView(state: CLIPreviewData.conversation(.markdown), actions: actions)
        .transcriptAppearance(TranscriptAppearance(style: style))
        .omnigentTheme(.nord)
    }

    @Test("static CLI rendering has no action controls until hover or focus")
    func staticRenderingHasNoControls() throws {
      let none = ConversationActions()
      let all = ConversationActions(
        forkFrom: { _ in }, messageURL: { _ in URL(string: "https://example.com/m") })
      func render(_ style: TranscriptStyle, _ actions: ConversationActions) throws
        -> RenderSupport.Rendered
      {
        try RenderSupport.render(
          transcript(style, actions: actions), width: 900, height: 900, scheme: .dark,
          layout: .regular)
      }
      // CLI looks the same whether Copy, Fork and Copy link exist or not: nothing is drawn.
      #expect(difference(try render(.cli, none), try render(.cli, all)) == 0)
      // Chat keeps the last answer's row shown, so the same comparison sees Fork and Copy link.
      #expect(difference(try render(.chat, none), try render(.chat, all)) > 0)
    }

    @Test("a message link flashes its CLI row")
    @MainActor
    func linkedMessageFlashes() throws {
      let state = CLIPreviewData.conversation(.markdown)
      let target = try #require(state.rows.first { $0.role == .user }?.id)
      let focus = TranscriptFocus()
      func render() throws -> RenderSupport.Rendered {
        try RenderSupport.render(
          transcript(.cli, actions: ConversationActions()).environment(\.transcriptFocus, focus),
          width: 900, height: 900, scheme: .dark, layout: .regular)
      }
      let plain = try render()
      focus.flash(target)
      let flashed = try render()
      try RenderSupport.write(flashed, name: "cli-message-flash")
      #expect(difference(plain, flashed) > 0.005, "the linked CLI row did not flash")
    }

    @Test("the touch composer and the Appearance screen render at phone width")
    func touch() throws {
      for scenario in [CLIPreviewScenario.markdown, .streaming] {
        let phone = try RenderSupport.render(
          CLIPreviewScreen(scenario: scenario)
            .environment(\.composerLayoutStyle, .touch)
            .transcriptAppearance(TranscriptAppearance(style: .cli, outputRendering: .styled))
            .omnigentTheme(.nord),
          width: 393, height: 852, scheme: .dark, layout: .compact)
        #expect(RenderSupport.inkCoverage(phone) > 0.01)
        try RenderSupport.write(phone, name: "cli-touch-\(scenario.rawValue)")
      }
      let defaults = try #require(UserDefaults(suiteName: "cli-render-appearance"))
      let settings = try RenderSupport.render(
        AppearanceSettingsView(preferences: ThemePreferences(defaults: defaults))
          .omnigentTheme(.omni),
        width: 393, height: 1_100, scheme: .light, layout: .compact)
      #expect(RenderSupport.inkCoverage(settings) > 0.01)
      try RenderSupport.write(settings, name: "cli-appearance-settings")
    }

    @Test("the reference screenshots' scenarios in Nord and the other themes")
    func screenshots() throws {
      for themeCase in Self.themes {
        let (name, theme, scheme) = (themeCase.name, themeCase.theme, themeCase.scheme)
        let markdown = try RenderSupport.render(
          screen(.markdown, theme: theme), width: 990, height: 860, scheme: scheme,
          layout: .regular)
        try RenderSupport.write(markdown, name: "cli-\(name)")
        let agents = try RenderSupport.render(
          screen(.agents, theme: theme), width: 990, height: 920, scheme: scheme, layout: .regular)
        try RenderSupport.write(agents, name: "cli-\(name)-agents")
      }
      for rendering in OutputRendering.allCases {
        let rendered = try RenderSupport.render(
          screen(.markdown, rendering: rendering), width: 990, height: 860, scheme: .dark,
          layout: .regular)
        try RenderSupport.write(rendered, name: "cli-render-\(rendering.rawValue)-nord")
      }
      for scenario in [CLIPreviewScenario.approval, .streaming] {
        let rendered = try RenderSupport.render(
          screen(scenario), width: 990, height: 760, scheme: .dark, layout: .regular)
        try RenderSupport.write(rendered, name: "cli-nord-\(scenario.rawValue)")
      }
      let phone = try RenderSupport.render(
        screen(.agents, theme: .nord), width: 393, height: 852, scheme: .dark, layout: .compact)
      try RenderSupport.write(phone, name: "cli-iphone")
      let chatPlain = try RenderSupport.render(
        screen(.markdown, style: .chat, rendering: .plain, theme: .omni), width: 990,
        height: 860, scheme: .dark, layout: .regular)
      try RenderSupport.write(chatPlain, name: "cli-chat-plain")
    }
  }
#endif
