#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// Shows what the appearance host gave the views below it.
  private struct WindowStyleReader: View {
    @Environment(\.transcriptAppearance) private var appearance
    @Environment(\.transcriptWindow) private var window

    var body: some View {
      VStack {
        Text(verbatim: appearance.isCLI ? "style is cli" : "style is chat")
        Text(
          verbatim: window == nil ? "no controls" : "controls for \(window?.style.rawValue ?? "")")
      }
    }
  }

  /// Presents Appearance as iPhone and iPad do: a sheet with a Done button.
  private struct AppearanceSheetHost: View {
    let preferences: ThemePreferences
    @State private var isPresented = true

    init(preferences: ThemePreferences) {
      self.preferences = preferences
    }

    var body: some View {
      Text(verbatim: isPresented ? "sheet is up" : "sheet went away")
        .sheet(isPresented: $isPresented) {
          AppearanceSettingsView(preferences: preferences).frame(width: 500, height: 400)
        }
    }
  }

  @Suite("Transcript settings", .serialized)
  @MainActor
  struct TranscriptSettingsTests {
    init() {
      SystemSideEffects.reset()
    }

    private func privateDefaults() throws -> UserDefaults {
      try #require(UserDefaults(suiteName: "transcript-settings-\(UUID().uuidString)"))
    }

    private func settings(_ preferences: TranscriptPreferences) -> OffscreenWindow<AnyView> {
      transcriptScreen(
        Form { TranscriptSettingsSection(preferences: preferences) }.formStyle(.grouped),
        width: 620, height: 500)
    }

    @Test("Each style explains itself and offers its own text size")
    func styleText() throws {
      let preferences = TranscriptPreferences(defaults: try privateDefaults())
      preferences.style = .chat
      let chat = settings(preferences)
      defer { chat.close() }
      #expect(try chat.shows("Text size"))
      #expect(try !chat.shows("CLI font size"))
      #expect(try chat.shows("Chat shows your messages in bubbles on the right."))
      #expect(try chat.shows(preferences.outputRendering.detail))

      preferences.style = .cli
      chat.settle()
      #expect(try chat.shows("CLI font size"))
      #expect(try !chat.shows("Text size"))
      #expect(
        try chat.shows(
          "CLI shows the conversation like a terminal. Copy, Fork and other actions appear "
            + "on hover."))
    }

    @Test("Clicking the style control switches the device's style and its text size row")
    func styleControl() throws {
      let preferences = TranscriptPreferences(defaults: try privateDefaults())
      preferences.style = .chat
      let screen = settings(preferences)
      defer { screen.close() }
      let segmented = try #require(screen.allViews.compactMap { $0 as? NSSegmentedControl }.first)
      let bounds = segmented.convert(segmented.bounds, to: screen.host)
      try screen.click(CGPoint(x: bounds.maxX - 8, y: bounds.midY))
      #expect(preferences.style == TranscriptStyle.allCases.last)
      #expect(try screen.shows("CLI font size"))
    }

    @Test("The steppers change the text size for the style on show, inside its range")
    func steppers() throws {
      let preferences = TranscriptPreferences(defaults: try privateDefaults())
      preferences.style = .chat
      preferences.chatFontSize = 15
      let screen = settings(preferences)
      defer { screen.close() }
      #expect(try screen.shows("15 pt"))
      let stepper = try #require(screen.allViews.compactMap { $0 as? NSStepper }.first)
      try stepUp(stepper, on: screen)
      #expect(preferences.chatFontSize == 16)
      #expect(try screen.shows("16 pt"))

      preferences.style = .cli
      preferences.fontSize = TranscriptAppearance.fontSizes.upperBound
      screen.settle()
      let cliStepper = try #require(screen.allViews.compactMap { $0 as? NSStepper }.first)
      try stepUp(cliStepper, on: screen)
      #expect(preferences.fontSize == TranscriptAppearance.fontSizes.upperBound)
    }

    private func stepUp(_ stepper: NSStepper, on screen: OffscreenWindow<AnyView>) throws {
      let frame = stepper.convert(stepper.bounds, to: screen.host)
      try screen.click(CGPoint(x: frame.midX, y: frame.midY - frame.height / 4))
    }

    @Test("The pickers remember their choice for the style on show")
    func pickers() throws {
      let preferences = TranscriptPreferences(defaults: try privateDefaults())
      preferences.style = .chat
      preferences.setOutputRendering(.allCases[0], for: .cli)
      let screen = settings(preferences)
      defer { screen.close() }
      let popUps = screen.allViews.compactMap { $0 as? NSPopUpButton }
      #expect(popUps.count == 2)
      let rendering = try #require(popUps.first)
      let last = try #require(OutputRendering.allCases.last)
      let frame = rendering.convert(rendering.bounds, to: screen.host)
      let menu = try screen.openMenu(CGPoint(x: frame.midX, y: frame.midY))
      try screen.choose(last.title, in: menu)
      #expect(preferences.outputRendering(for: .chat) == last)
      #expect(preferences.outputRendering(for: .cli) == OutputRendering.allCases[0])
    }

    @Test("A stored setting that can't be read says so under the section")
    func readErrors() throws {
      let defaults = try privateDefaults()
      defaults.set("sideways", forKey: TranscriptPreferences.styleKey)
      let preferences = TranscriptPreferences(defaults: defaults)
      let error = try #require(preferences.readErrors.first)
      let screen = settings(preferences)
      defer { screen.close() }
      #expect(try screen.shows(error.description))
    }

    @Test("A window with no style of its own follows the device")
    func followsDevice() throws {
      let preferences = TranscriptPreferences(defaults: try privateDefaults())
      preferences.style = .chat
      let screen = transcriptScreen(WindowStyleReader().transcriptAppearance(from: preferences))
      defer { screen.close() }
      #expect(try screen.shows("style is chat"))
      #expect(try screen.shows("controls for chat"))
      preferences.style = .cli
      screen.settle()
      #expect(try screen.shows("style is cli"))
      #expect(try screen.shows("controls for cli"))
    }

    @Test("The title menu switches this window's style; the device's own style clears the choice")
    func titleMenuStyle() throws {
      let preferences = TranscriptPreferences(defaults: try privateDefaults())
      preferences.style = .chat
      var stored = ""
      let store = TranscriptWindowStyleStore()
      store.storage = Binding(get: { stored }, set: { stored = $0 })

      let onChat = transcriptScreen(
        transcriptTitleMenuItems(
          TranscriptTitleMenu(
            window: TranscriptWindowControls(style: .chat, preferences: preferences, window: store),
            openAppearance: nil)))
      defer { onChat.close() }
      #expect(try onChat.shows("Use CLI Style"))
      #expect(try !onChat.shows("Appearance\u{2026}"))
      try onChat.clickControl(at: 0)
      #expect(stored == TranscriptStyle.cli.rawValue)
      #expect(preferences.style == .chat)

      let onCLI = transcriptScreen(
        transcriptTitleMenuItems(
          TranscriptTitleMenu(
            window: TranscriptWindowControls(style: .cli, preferences: preferences, window: store),
            openAppearance: nil)))
      defer { onCLI.close() }
      #expect(try onCLI.shows("Use Chat Style"))
      try onCLI.clickControl(at: 0)
      #expect(stored.isEmpty)
    }

    @Test("Controls are equal only for the same style, preferences and window")
    func controlsEquality() throws {
      let preferences = TranscriptPreferences(defaults: try privateDefaults())
      let store = TranscriptWindowStyleStore()
      let controls = TranscriptWindowControls(style: .chat, preferences: preferences, window: store)
      #expect(
        controls == TranscriptWindowControls(style: .chat, preferences: preferences, window: store))
      #expect(
        controls != TranscriptWindowControls(style: .cli, preferences: preferences, window: store))
      #expect(
        controls
          != TranscriptWindowControls(
            style: .chat, preferences: preferences, window: TranscriptWindowStyleStore()))
      #expect(
        controls
          != TranscriptWindowControls(
            style: .chat, preferences: TranscriptPreferences(defaults: try privateDefaults()),
            window: store))
    }

    @Test("A window without its scene's storage ignores a style change instead of crashing")
    func storeWithoutStorage() {
      TranscriptWindowStyleStore().setStyle("cli")
    }

    @Test("The title menu's Appearance item opens the host's settings")
    func titleMenuAppearance() throws {
      let presenter = AppearanceSettingsPresenter()
      let log = HostLog()
      presenter.open = { log.add("opened") }
      let screen = transcriptScreen(
        transcriptTitleMenuItems(
          TranscriptTitleMenu(
            window: nil, openAppearance: OpenAppearanceSettingsAction(presenter: presenter))))
      defer { screen.close() }
      #expect(try !screen.shows("Use CLI Style"))
      try screen.clickControl(at: 0)
      #expect(log.entries == ["opened"])
      let samePresenter = OpenAppearanceSettingsAction(presenter: presenter)
      #expect(OpenAppearanceSettingsAction(presenter: presenter) == samePresenter)
      #expect(
        samePresenter != OpenAppearanceSettingsAction(presenter: AppearanceSettingsPresenter()))
    }

    @Test("A presenter with nothing to open does nothing")
    func presenterWithoutOpen() {
      OpenAppearanceSettingsAction(presenter: AppearanceSettingsPresenter())()
    }

    @Test("The appearance host publishes the settings action and preferences to what's below")
    func appearanceHost() throws {
      let preferences = ThemePreferences(defaults: try privateDefaults())
      let seen = AppearanceHostProbe.Seen()
      let screen = transcriptScreen(
        AppearanceHostProbe(seen: seen).appearanceSettings(preferences))
      defer { screen.close() }
      screen.settle()
      #expect(seen.preferences === preferences)
      #expect(seen.hasOpenAction)
    }

    @Test("Appearance as its own screen shows the settings, and Done dismisses it")
    func appearanceScreen() throws {
      let preferences = ThemePreferences(defaults: try privateDefaults())
      let screen = transcriptScreen(AppearanceSheetHost(preferences: preferences))
      defer { screen.close() }
      screen.settle()
      #expect(screen.window.attachedSheet != nil)
      #expect(try screen.shows("Transcript"))
      #expect(try screen.shows("Done"))
      try screen.press(keyCode: 36, characters: "\r")
      screen.settle()
      #expect(screen.window.attachedSheet == nil)
      #expect(try screen.shows("sheet went away"))
    }
  }

  /// Reads what ``SwiftUICore/View/appearanceSettings(_:)`` publishes.
  private struct AppearanceHostProbe: View {
    @MainActor
    final class Seen {
      var preferences: ThemePreferences?
      var hasOpenAction = false
    }

    let seen: Seen
    @Environment(\.openAppearanceSettings) private var open
    @Environment(\.themePreferences) private var preferences

    var body: some View {
      seen.preferences = preferences
      seen.hasOpenAction = open != nil
      return Text("below the host")
    }
  }
#endif
