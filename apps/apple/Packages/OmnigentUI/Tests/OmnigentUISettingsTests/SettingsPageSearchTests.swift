#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  @Suite("Settings page, searched", .serialized)
  @MainActor
  struct SettingsPageSearchTests {
    private let selection = EditedValue("General")
    private let focusRequest = EditedValue(false)
    private let log = ActionLog()

    private var categories: [SettingsPageCategory] {
      [
        SettingsPageCategory(
          "General", systemImage: "gearshape",
          content: AnyView(Form { Text(verbatim: "General pane") }.formStyle(.grouped))),
        SettingsPageCategory(
          "Appearance", systemImage: "paintpalette",
          content: AnyView(
            Form {
              Toggle("Mode", isOn: .constant(true)).settingsSearchAnchor("settings.appearance")
            }
            .formStyle(.grouped))),
        SettingsPageCategory(
          "Servers", systemImage: "network", isWide: true,
          content: AnyView(Text(verbatim: "Servers pane"))),
      ]
    }

    private func screen() -> OffscreenWindow<some View> {
      SystemSideEffects.reset()
      let log = log
      let entries = SettingsSearchIndex.entries(
        SettingsSearchScope(
          categories: categories.map(\.id), serverPanes: [.archived], serversCategory: "Servers",
          isMac: true))
      let search = SettingsSearchConfiguration(
        entries: entries, focusRequest: focusRequest.binding,
        openServerPane: { log.record("pane \($0.rawValue)") })
      return OffscreenWindow(
        SettingsPage(
          categories: categories, selection: selection.binding, search: search,
          back: { log.record("back") }
        )
        .environment(\.flattensGlass, true), width: 900, height: 600)
    }

    private func type(_ text: String, in screen: OffscreenWindow<some View>) throws {
      let field = try #require(screen.searchFields.first)
      screen.window.makeFirstResponder(field)
      try screen.type(text)
      screen.settle(0.1)
    }

    @Test("typing lists matches in place of the categories, and Return opens the first")
    func returnOpensFirst() throws {
      let screen = screen()
      defer { screen.close() }
      try type("dark", in: screen)
      #expect(try screen.shows("Appearance › Theme"))
      #expect(try !screen.shows("Servers"))
      try screen.press(keyCode: 36, characters: "\r")
      screen.settle(0.3)
      #expect(selection.value == "Appearance")
      #expect(try screen.shows("Mode"))
      #expect(try screen.shows("Servers"), "the categories are back")
    }

    @Test("a server pane result asks for that pane")
    func serverPane() throws {
      let screen = screen()
      defer { screen.close() }
      try type("archived sessions", in: screen)
      try screen.press(keyCode: 36, characters: "\r")
      #expect(log.entries == ["pane archived"])
    }

    @Test("Escape clears a query before it leaves Settings")
    func escapeClearsFirst() throws {
      let screen = screen()
      defer { screen.close() }
      try type("theme", in: screen)
      try screen.press(keyCode: 53, characters: "\u{1B}")
      screen.settle(0.1)
      #expect(log.entries.isEmpty)
      #expect(try #require(screen.searchFields.first).stringValue.isEmpty)
      #expect(try screen.pressShortcut(keyCode: 53, characters: "\u{1B}", modifiers: []))
      #expect(log.entries == ["back"])
    }

    @Test("Search Settings… puts the keyboard in the field")
    func focusRequestFocuses() async throws {
      focusRequest.value = true
      let screen = screen()
      defer { screen.close() }
      await screen.settleTasks()
      screen.settle(0.1)
      let field = try #require(screen.searchFields.first)
      // AppKit declares the field editor's `delegate` unowned(unsafe); it is only compared.
      let delegate = unsafe (screen.window.firstResponder as? NSText)?.delegate
      #expect(delegate === field)
      #expect(!focusRequest.value)
    }
  }
#endif
