#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  @Suite("Settings page, clicked", .serialized)
  @MainActor
  struct SettingsPageTests {
    private let selection = EditedValue("General")
    private let darkCanvas = EditedValue(false)
    private let log = ActionLog()

    /// Two form panes and a wide one, each with a text or control only it has.
    private var categories: [SettingsPageCategory] {
      let darkCanvas = darkCanvas
      return [
        SettingsPageCategory(
          "General", systemImage: "gearshape",
          content: AnyView(Form { Text(verbatim: "General pane") }.formStyle(.grouped))),
        SettingsPageCategory(
          "Appearance", systemImage: "paintpalette",
          content: AnyView(
            Form { Toggle("Dark canvas", isOn: darkCanvas.binding) }.formStyle(.grouped))),
        SettingsPageCategory(
          "Servers", systemImage: "network", isWide: true,
          content: AnyView(Text(verbatim: "Servers pane"))),
      ]
    }

    private func screen() -> OffscreenWindow<some View> {
      SystemSideEffects.reset()
      let selection = selection
      let log = log
      return OffscreenWindow(
        SettingsPage(
          categories: categories, selection: selection.binding, back: { log.record("back") }
        )
        .environment(\.flattensGlass, true), width: 900, height: 600)
    }

    private let panes = ["General pane", "Dark canvas", "Servers pane"]

    @Test("every category has a row in the sidebar, under Back")
    func sidebarRows() throws {
      let screen = screen()
      defer { screen.close() }
      let shown = try screen.shownText()
      #expect(shown.contains("Back"))
      #expect(try #require(screen.list).numberOfRows == 3)
      for category in categories {
        #expect(shown.contains(category.title), "\(category.title) in \(shown)")
      }
    }

    @Test("a click on a category's row shows its pane and no other", arguments: [0, 1, 2])
    func clickShowsPane(row: Int) throws {
      // Start on another category, so the click is what shows this one.
      selection.value = categories[(row + 1) % 3].id
      let screen = screen()
      defer { screen.close() }
      #expect(try !screen.shows(panes[row]))
      try screen.clickRow(row)
      #expect(selection.value == categories[row].id)
      for (index, pane) in panes.enumerated() {
        #expect(try screen.shows(pane) == (index == row), "\(pane) after clicking row \(row)")
      }
    }

    @Test("the list's own selection, as the arrow keys move it, shows the pane too")
    func listSelection() throws {
      let screen = screen()
      defer { screen.close() }
      try screen.selectRow(2)
      #expect(selection.value == "Servers")
      #expect(try screen.shows("Servers pane"))
    }

    @Test("a form pane sits under its title; a wide pane takes the whole area")
    func headings() throws {
      /// How many times the window draws `title` while it shows `category`.
      func drawn(_ title: String, showing category: String) throws -> Int {
        selection.value = category
        let screen = screen()
        defer { screen.close() }
        return try screen.shownText().filter { $0 == title }.count
      }
      let appearanceRow = try drawn("Appearance", showing: "General")
      #expect(appearanceRow > 0)
      #expect(try drawn("Appearance", showing: "Appearance") == appearanceRow + 1, "its heading")
      let serversRow = try drawn("Servers", showing: "General")
      #expect(serversRow > 0)
      #expect(try drawn("Servers", showing: "Servers") == serversRow, "no heading over it")
    }

    @Test("a setting changed on a pane is written through")
    func paneControlsWork() throws {
      selection.value = "Appearance"
      let screen = screen()
      defer { screen.close() }
      try screen.set(#require(screen.switches.first), isOn: true)
      #expect(darkCanvas.value)
    }

    @Test("a category the page doesn't have shows the first one")
    func unknownSelection() throws {
      selection.value = "No such category"
      let screen = screen()
      defer { screen.close() }
      #expect(try screen.shows("General pane"))
    }

    @Test("Back, Escape and Command-W each leave Settings")
    func leaving() throws {
      let screen = screen()
      defer { screen.close() }
      // Back is the page's first control, above the rows.
      try screen.clickControl(at: 0)
      #expect(log.entries == ["back"])
      #expect(try screen.pressShortcut(keyCode: 53, characters: "\u{1B}", modifiers: []))
      #expect(log.entries == ["back", "back"])
      #expect(try screen.pressShortcut(keyCode: 13, characters: "w", modifiers: .command))
      #expect(log.entries == ["back", "back", "back"])
      #expect(selection.value == "General", "leaving keeps the category")
    }

    @Test("with no categories the page is only its sidebar")
    func empty() throws {
      SystemSideEffects.reset()
      let screen = OffscreenWindow(
        SettingsPage(categories: [], selection: selection.binding, back: {})
          .environment(\.flattensGlass, true), width: 900, height: 600)
      defer { screen.close() }
      #expect(try screen.shows("Back"))
      #expect(try #require(screen.list).numberOfRows == 0)
      #expect(try !screen.shows("pane"))
    }
  }
#endif
