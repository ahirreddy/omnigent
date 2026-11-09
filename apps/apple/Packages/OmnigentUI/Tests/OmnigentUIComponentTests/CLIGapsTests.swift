#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// Reads the Settings action the appearance host publishes.
  private struct OpenProbe: View {
    let seen: @MainActor (OpenAppearanceSettingsAction?) -> Void
    @Environment(\.openAppearanceSettings) private var open

    var body: some View {
      seen(open)
      return Text(verbatim: "below the host")
    }
  }

  @Suite("Transcript CLI: small gaps", .serialized)
  @MainActor
  struct CLIGapsTests {
    init() {
      SystemSideEffects.reset()
    }

    private func preferences() throws -> TranscriptPreferences {
      let suite = "cli-gaps-\(UUID().uuidString)"
      return TranscriptPreferences(defaults: try #require(UserDefaults(suiteName: suite)))
    }

    private func menuItems(
      _ preferences: TranscriptPreferences, style: TranscriptStyle,
      store: TranscriptWindowStyleStore
    ) -> OffscreenWindow<AnyView> {
      let controls = TranscriptWindowControls(
        style: style, preferences: preferences, window: store)
      return transcriptScreen(
        Form { TranscriptMenuItems(window: controls) }, width: 500, height: 300)
    }

    private func choose(
      _ title: String, inPopUp index: Int, on screen: OffscreenWindow<AnyView>
    ) throws {
      let popUps = screen.allViews.compactMap { $0 as? NSPopUpButton }
      #expect(popUps.count == 3)
      let frame = popUps[index].convert(popUps[index].bounds, to: screen.host)
      let menu = try screen.openMenu(CGPoint(x: frame.midX, y: frame.midY))
      try screen.choose(title, in: menu)
    }

    @Test("The View menu's style applies to this window; the device default stays")
    func menuStyle() throws {
      let preferences = try preferences()
      preferences.style = .chat
      let store = TranscriptWindowStyleStore()
      var stored = ""
      store.storage = Binding(get: { stored }, set: { stored = $0 })
      let screen = menuItems(preferences, style: .chat, store: store)
      defer { screen.close() }
      try choose(TranscriptStyle.cli.title, inPopUp: 0, on: screen)
      #expect(stored == TranscriptStyle.cli.rawValue)
      #expect(preferences.style == .chat)
    }

    @Test("The View menu's rendering and width apply to the window's style only")
    func menuRenderingAndWidth() throws {
      let preferences = try preferences()
      let rendering = try #require(OutputRendering.allCases.last)
      let width = try #require(TranscriptContentWidth.allCases.last)
      let other = TranscriptContentWidth.allCases[0]
      preferences.setOutputRendering(OutputRendering.allCases[0], for: .chat)
      preferences.setOutputRendering(OutputRendering.allCases[0], for: .cli)
      preferences.setContentWidth(other, for: .chat)
      preferences.setContentWidth(other, for: .cli)
      let screen = menuItems(preferences, style: .cli, store: TranscriptWindowStyleStore())
      defer { screen.close() }
      try choose(rendering.title, inPopUp: 1, on: screen)
      try choose(width.title, inPopUp: 2, on: screen)
      #expect(preferences.outputRendering(for: .cli) == rendering)
      #expect(preferences.contentWidth(for: .cli) == width)
      #expect(preferences.outputRendering(for: .chat) == OutputRendering.allCases[0])
      #expect(preferences.contentWidth(for: .chat) == other)
    }

    @Test("The commands build their group with nothing focused")
    func commandsBuild() {
      _ = TranscriptCommands().body
    }

    @Test("On the Mac, opening Appearance goes to the Settings window, not a sheet")
    func openSettingsOnMac() throws {
      let suite = "cli-gaps-\(UUID().uuidString)"
      let preferences = ThemePreferences(defaults: try #require(UserDefaults(suiteName: suite)))
      var open: OpenAppearanceSettingsAction?
      let screen = transcriptScreen(
        OpenProbe { open = $0 }.appearanceSettings(preferences))
      defer { screen.close() }
      screen.settle()
      let openSettings = try #require(open)
      openSettings()
      screen.settle()
      #expect(screen.window.attachedSheet == nil)
      #expect(SystemSideEffects.record.shownWindowTitles.isEmpty)
    }

    @Test("A color that can't reach the contrast either way falls back to the preferred end")
    func impossibleContrast() {
      let mid = SRGB(red: 0.5, green: 0.5, blue: 0.5)
      // 21:1 is black on white, so 30:1 is out of reach for any color.
      #expect(mid.ensuringContrast(30, against: [.black]) == .white)
      #expect(mid.ensuringContrast(30, against: [.white]) == .black)
    }

    private func toolLine(result: Row) -> OffscreenWindow<AnyView> {
      let call = TranscriptFixture.toolCall("c", title: "Bash", summary: "ls", status: "completed")
      return transcriptScreen(
        CLIToolLines(entries: [ToolEntry(call: call, result: result)])
          .transcriptAppearance(TranscriptAppearance(style: .cli, outputRendering: .styled)))
    }

    @Test("A result with text but no output section shows that text when opened")
    func resultTextOnly() throws {
      let screen = toolLine(result: Row(id: "r", role: .tool, text: "plain text", callId: "c"))
      defer { screen.close() }
      let menu = try #require(try screen.firstContextMenu())
      try screen.choose("Show output", in: menu)
      #expect(try screen.shows("plain text"))
    }

    @Test("A result with empty text counts as no output")
    func resultTextEmpty() throws {
      let screen = toolLine(result: Row(id: "r", role: .tool, text: "", callId: "c"))
      defer { screen.close() }
      let menu = try #require(try screen.firstContextMenu())
      try screen.choose("Show output", in: menu)
      #expect(try screen.shows("(no output)"))
    }

    @Test("A failed sub-agent's line carries its error; a finished one's doesn't")
    func failedSubagentError() throws {
      func section(_ id: String, state: String) -> EventSection {
        EventSection(
          id: "child-\(id)", title: id, summary: state,
          details: [
            DetailSection(id: "state", title: "State", text: state),
            DetailSection(id: "error", title: "Error", text: "\(id) broke"),
          ],
          sessionId: id)
      }
      var state = PreviewData.conversation
      state.rows = []
      state.sections = [section("bad", state: "failed"), section("fine", state: "ready")]
      let screen = transcriptScreen(CLISubagentLines(state: state, actions: ConversationActions()))
      defer { screen.close() }
      #expect(try screen.shows("bad broke"))
      #expect(try !screen.shows("fine broke"))
    }

    @Test("A line's defaults: no color and no bold unless asked")
    func lineParts() {
      var line = CLILineText()
      line.append("plain")
      #expect(line.parts.first?.bold == false)
      #expect(line.parts.first?.color == nil)
      #expect(line.plain == "plain")
    }
  }
#endif
